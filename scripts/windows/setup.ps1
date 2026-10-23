<#
.SYNOPSIS
Sets up the Infracost Azure integration with the az CLI.

.DESCRIPTION
Gives the same result as the terraform-azure-integration module. Safe to run
more than once: only the items that do not exist are created. Writes progress
to stderr and the values for Infracost to stdout as JSON.

.PARAMETER ClientId
Client ID of the Infracost multi-tenant application.

.PARAMETER TenantId
Tenant to use. Fails if the az CLI is signed in to another tenant.

.PARAMETER Subscription
Subscription that hosts the billing exports. Fails if the az CLI targets another subscription.

.PARAMETER ManagementGroups
Management group names where Infracost gets read access. Default: tenant root management group.

.PARAMETER Roles
Roles on the management groups.

.PARAMETER Owners
Object IDs to add as owners of the service principal. Existing owners are kept.

.PARAMETER BillingAgreementType
Billing agreement of the billing account: EA or MCA.

.PARAMETER BillingAccountId
EA enrollment number, or MCA billing account ID.

.PARAMETER SkipBillingAccess
Do not assign the billing reader role.

.PARAMETER Location
Region of the storage account and cost export.

.PARAMETER ResourceGroup
Resource group of the storage account.

.PARAMETER StorageAccount
Name of the storage account. Default: derived from the tenant ID. Must not exist, or must be created by setup.ps1.

.PARAMETER ExistingExport
Use a FOCUS cost export that exists, as <storage_account_id>,<container>,<root_path>.
Only the blob reader role is assigned.

.PARAMETER SkipBillingExports
Do not set up billing exports.

.PARAMETER DryRun
Print the changes. Do not apply them.

.PARAMETER SkipPreflight
Do not check the permissions before the changes.

.EXAMPLE
.\setup.ps1 -DryRun -ClientId <infracost-client-id> -BillingAgreementType EA -BillingAccountId 12345678 -Location westeurope

.LINK
https://github.com/infracost/terraform-azure-integration/tree/main/scripts
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$ClientId,
  [string]$TenantId,
  [string]$Subscription,
  [string[]]$ManagementGroups = @(),
  [string[]]$Roles = @('Reader', 'Cost Management Reader', 'Monitoring Reader'),
  [string[]]$Owners = @(),
  [ValidateSet('EA', 'MCA')][string]$BillingAgreementType,
  [string]$BillingAccountId,
  [switch]$SkipBillingAccess,
  [string]$Location,
  [string]$ResourceGroup = 'infracost-billing-exports',
  [string]$StorageAccount,
  [string]$ExistingExport,
  [switch]$SkipBillingExports,
  [switch]$DryRun,
  [switch]$SkipPreflight
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

# IDs of the created items, for the output.
$RoleAssignmentIds = [ordered]@{}
$BillingRoleAssignmentId = $null
$ExportId = $null
$ExportPrincipalId = $null
$BillingExports = $null

# Stops if an option is missing or not valid.
function Assert-Arguments {
  $script:ManagementGroups = Split-ListArgument $ManagementGroups
  $script:Roles = Split-ListArgument $Roles
  $script:Owners = Split-ListArgument $Owners
  if ($ClientId -notmatch $GuidPattern) { Stop-WithError "-ClientId must be a GUID." }
  Assert-TenantAndSubscriptionArguments
  if ($Roles.Count -eq 0) { Stop-WithError "-Roles must contain at least one role." }
  if (-not $SkipBillingExports -and -not $ExistingExport -and -not $Location) {
    Stop-WithError "-Location is required to create the billing exports."
  }
  Assert-BillingArguments
  if ($ExistingExport) { Read-ExistingExport }
  Assert-StorageAccountName
  foreach ($owner in $Owners) {
    if ($owner -notmatch $GuidPattern) { Stop-WithError "-Owners must contain object ID GUIDs." }
  }
}

# Stops if the billing account does not have the given billing agreement type.
function Confirm-BillingAccount {
  if ($SkipBillingAccess) { return }
  $expectedAgreementType = if ($BillingAgreementType -eq 'EA') { $EaAgreementType } else { $McaAgreementType }
  $billingAccountUrl = "/providers/Microsoft.Billing/billingAccounts/${BillingAccountId}?api-version=$BillingApiVersion"
  $billingAccount = Invoke-Az -Arguments @('rest', '--method', 'GET', '--url', $billingAccountUrl) -AllowFailure
  if ($null -eq $billingAccount) { Stop-WithError "cannot read billing account $BillingAccountId." }
  $actualAgreementType = $billingAccount.properties.agreementType
  if ($actualAgreementType -ne $expectedAgreementType) {
    Stop-WithError "-BillingAgreementType is $BillingAgreementType, but the billing account is $actualAgreementType."
  }
}

# Stops if the storage account exists and the setup script did not create it.
function Assert-StorageAccountOwner {
  if ($SkipBillingExports -or $ExistingExport) { return }
  if (-not (Test-ResourceExists $ExportStorageAccountId)) { return }
  if (-not (Get-StorageAccountVersionTag)) {
    Stop-WithError "storage account $StorageAccount exists and does not have the $VersionTagName tag. Pass -StorageAccount with a different name, or use -ExistingExport."
  }
}

# Checks the permissions to register the resource providers and create the billing exports storage.
function Invoke-PreflightBillingExportsStorage {
  $unregisteredResourceProviders = @(Get-UnregisteredResourceProviders)
  foreach ($namespace in $unregisteredResourceProviders) {
    Assert-ArmActions "/subscriptions/$ActiveSubscriptionId" "Resource provider registration" @("$namespace/register/action")
  }

  $resourceGroupScope = if (Test-ResourceGroupExists) {
    "/subscriptions/$ActiveSubscriptionId/resourceGroups/$ResourceGroup"
  } else {
    "/subscriptions/$ActiveSubscriptionId"
  }
  Assert-ArmActions $resourceGroupScope "Billing exports storage" @(
    'Microsoft.Resources/subscriptions/resourceGroups/write',
    'Microsoft.Storage/storageAccounts/write',
    'Microsoft.Storage/storageAccounts/blobServices/containers/write',
    'Microsoft.Storage/storageAccounts/managementPolicies/write',
    'Microsoft.Authorization/roleAssignments/write'
  )

  if (Test-ResourceExists $ExportStorageAccountId) { return }
  if ($unregisteredResourceProviders -contains 'Microsoft.Storage') {
    Add-UncheckedPermission "Storage account name: cannot check if $StorageAccount is available until the run registers Microsoft.Storage"
    return
  }
  $nameCheck = Invoke-Az -Arguments @('storage', 'account', 'check-name', '--name', $StorageAccount) -AllowFailure
  if (-not $nameCheck) {
    Add-UncheckedPermission "Storage account name: cannot check if $StorageAccount is available"
  } elseif ($nameCheck.nameAvailable -eq $false) {
    Add-PreflightFailure "Storage account name $StorageAccount is in use. Pass -StorageAccount with a different name"
  } else {
    Add-PreflightPass "Storage account name $StorageAccount is available"
  }
}

# Checks that the existing export storage account exists and that you can assign roles on it.
function Invoke-PreflightExistingExport {
  if (Test-ResourceExists $ExistingStorageAccountId) {
    Add-PreflightPass "Existing export: storage account $ExistingStorageAccountId exists"
    Assert-ArmActions $ExistingStorageAccountId "Blob reader role on the existing export" @('Microsoft.Authorization/roleAssignments/write')
  } else {
    Add-PreflightFailure "Existing export: storage account $ExistingStorageAccountId not found"
  }
}

# Checks all permissions before the first change.
function Invoke-Preflight {
  if ($SkipPreflight) { Write-Step "Skipping preflight"; return }
  Write-Step "Preflight"

  Assert-ServicePrincipalManagement "Service principal" $ServicePrincipalObjectId
  Assert-ManagementGroupRolePermissions @('Microsoft.Authorization/roleAssignments/read', 'Microsoft.Authorization/roleAssignments/write')
  if (-not $SkipBillingAccess) {
    Assert-BillingAccountRole "Billing reader role"
  }

  if (-not $SkipBillingExports -and $ExistingExport) {
    Invoke-PreflightExistingExport
  } elseif (-not $SkipBillingExports) {
    Invoke-PreflightBillingExportsStorage
    Assert-BillingAccountRole "FOCUS cost export"
  }

  Write-PreflightReport
}

# Creates the Infracost service principal if it does not exist, and sets its tags and owners.
function Set-ServicePrincipal {
  Write-Step "Service principal for application $ClientId"

  if (-not $ServicePrincipalObjectId) {
    $servicePrincipal = Invoke-AzMutation -Arguments @('ad', 'sp', 'create', '--id', $ClientId) `
      -DryRunResult @{ id = '<service-principal-object-id>' }
    $script:ServicePrincipalObjectId = $servicePrincipal.id
  }

  $servicePrincipalUrl = "$GraphUrl/servicePrincipals/$ServicePrincipalObjectId"
  Invoke-AzMutation -Arguments @('rest', '--method', 'PATCH', '--url', $servicePrincipalUrl, '--headers', 'Content-Type=application/json') -Body @{
    tags = @('WindowsAzureActiveDirectoryIntegratedApp', "${VersionTagName}:$ScriptVersion")
  } | Out-Null

  if ($Owners.Count -eq 0) { return }
  $existingOwners = Invoke-Az -Arguments @('rest', '--method', 'GET', '--url', "$servicePrincipalUrl/owners?`$select=id") -AllowFailure
  $existingOwnerIds = @($existingOwners.value | ForEach-Object { $_.id })
  foreach ($owner in $Owners) {
    if ($existingOwnerIds -contains $owner) { continue }
    Invoke-AzMutation -Arguments @('rest', '--method', 'POST', '--url', "$servicePrincipalUrl/owners/`$ref", '--headers', 'Content-Type=application/json') -Body @{
      '@odata.id' = "$GraphUrl/directoryObjects/$owner"
    } | Out-Null
  }
}

# Assigns a role to a principal on a scope, if the assignment does not exist. Returns the assignment ID.
function Set-RoleAssignment {
  param([string]$Scope, [string]$Role, [string]$Description, [string]$PrincipalId)
  $existing = @(Invoke-Az -AllowFailure -Arguments @(
      'role', 'assignment', 'list',
      '--assignee', $PrincipalId,
      '--scope', $Scope,
      '--role', $Role
    ))
  if ($existing.Count -gt 0 -and $existing[0]) { return $existing[0].id }

  $assignment = Invoke-AzMutation -DryRunResult @{ id = '<role-assignment-id>' } -Arguments @(
    'role', 'assignment', 'create',
    '--assignee-object-id', $PrincipalId,
    '--assignee-principal-type', 'ServicePrincipal',
    '--role', $Role,
    '--scope', $Scope,
    '--description', $Description
  )
  $assignment.id
}

# Assigns the read roles to Infracost on each management group.
function Set-ManagementGroupRoles {
  foreach ($name in $ManagementGroupIds.Keys) {
    foreach ($role in $Roles) {
      Write-Step "Role $role on management group $name"
      $RoleAssignmentIds["$name/$role"] = Set-RoleAssignment -Scope $ManagementGroupIds[$name] -Role $role `
        -Description "Infracost read-only access" -PrincipalId $ServicePrincipalObjectId
    }
  }
}

# Assigns the billing reader role to Infracost on the billing account.
function Set-BillingAccess {
  if ($SkipBillingAccess) { return }

  $billingAccountResourceId = "/providers/Microsoft.Billing/billingAccounts/$BillingAccountId"
  $roleDefinitionId = Get-BillingRoleDefinitionId
  Write-Step "Billing reader role on billing account $BillingAccountId"

  $properties = [ordered]@{
    principalId       = $ServicePrincipalObjectId
    principalTenantId = $ActiveTenantId
    roleDefinitionId  = "$billingAccountResourceId/billingRoleDefinitions/$roleDefinitionId"
  }

  if ($BillingAgreementType -eq 'EA') {
    Set-EnrollmentReader -BillingAccountResourceId $billingAccountResourceId -RoleDefinitionId $roleDefinitionId -Properties $properties
  } else {
    Set-BillingAccountReader -BillingAccountResourceId $billingAccountResourceId -RoleDefinitionId $roleDefinitionId -Properties $properties
  }
}

# Assigns the EnrollmentReader role on an EA enrollment.
function Set-EnrollmentReader {
  param([string]$BillingAccountResourceId, [string]$RoleDefinitionId, $Properties)
  $assignmentName = Get-UuidV5Url "$BillingAccountResourceId/$ServicePrincipalObjectId/$RoleDefinitionId"
  $assignmentResourceId = "$BillingAccountResourceId/billingRoleAssignments/$assignmentName"
  $assignment = Invoke-AzMutation -Arguments @('rest', '--method', 'PUT', '--url', "${assignmentResourceId}?api-version=$BillingApiVersion") `
    -Body @{ properties = $Properties } -DryRunResult @{ id = $assignmentResourceId }
  $script:BillingRoleAssignmentId = $assignment.id
}

# Assigns the billing account reader role on an MCA billing account, if the assignment does not exist.
function Set-BillingAccountReader {
  param([string]$BillingAccountResourceId, [string]$RoleDefinitionId, $Properties)
  $assignmentResourceId = "$BillingAccountResourceId/billingRoleAssignments/${RoleDefinitionId}_$ServicePrincipalObjectId"
  $existing = Invoke-Az -Arguments @('rest', '--method', 'GET', '--url', "${assignmentResourceId}?api-version=$BillingApiVersion") -AllowFailure
  if ($existing) {
    $script:BillingRoleAssignmentId = $existing.id
    return
  }
  $createUrl = "$BillingAccountResourceId/createBillingRoleAssignment?api-version=$BillingApiVersion"
  $assignment = Invoke-AzMutation -Arguments @('rest', '--method', 'POST', '--url', $createUrl) `
    -Body $Properties -DryRunResult @{ id = $assignmentResourceId }
  $script:BillingRoleAssignmentId = $assignment.id
}

# Registers the resource providers that the storage account and cost export need.
function Register-ResourceProviders {
  $unregisteredResourceProviders = @(Get-UnregisteredResourceProviders)
  foreach ($namespace in $unregisteredResourceProviders) {
    Write-Step "Resource provider $namespace"
    Invoke-AzMutation -Arguments @(
      'provider', 'register',
      '--namespace', $namespace,
      '--subscription', $ActiveSubscriptionId,
      '--wait'
    ) | Out-Null
  }
}

# Creates the resource group of the storage account, if it does not exist.
function Set-ResourceGroup {
  Write-Step "Resource group $ResourceGroup"
  if (Test-ResourceGroupExists) { return }
  Invoke-AzMutation -Arguments @(
    'group', 'create',
    '--name', $ResourceGroup,
    '--location', $Location,
    '--tags', "$VersionTagName=$ScriptVersion"
  ) | Out-Null
}

# Creates the storage account for the cost export, if it does not exist.
function Set-StorageAccount {
  Write-Step "Storage account $StorageAccount"
  $existing = Invoke-Az -Arguments @('storage', 'account', 'show', '--name', $StorageAccount, '--resource-group', $ResourceGroup) -AllowFailure
  if ($existing) { return }
  Invoke-AzMutation -Arguments @(
    'storage', 'account', 'create',
    '--name', $StorageAccount,
    '--resource-group', $ResourceGroup,
    '--location', $Location,
    '--sku', $StorageAccountSku,
    '--kind', 'StorageV2',
    '--min-tls-version', 'TLS1_2',
    '--https-only', 'true',
    '--allow-blob-public-access', 'false',
    '--allow-shared-key-access', 'false',
    '--tags', "$VersionTagName=$ScriptVersion"
  ) | Out-Null
  Invoke-AzMutation -Arguments @(
    'storage', 'account', 'update',
    '--name', $StorageAccount,
    '--resource-group', $ResourceGroup,
    '--set', 'defaultToOAuthAuthentication=true'
  ) | Out-Null
}

# Creates the blob container for the cost export, if it does not exist.
function Set-StorageContainer {
  Write-Step "Storage container $ExportContainer"
  $exists = Invoke-Az -AllowFailure -Arguments @(
    'storage', 'container-rm', 'exists',
    '--storage-account', $ExportStorageAccountId,
    '--name', $ExportContainer
  )
  if ($exists -and $exists.exists -eq $true) { return }
  Invoke-AzMutation -Arguments @(
    'storage', 'container-rm', 'create',
    '--storage-account', $ExportStorageAccountId,
    '--name', $ExportContainer,
    '--public-access', 'off'
  ) | Out-Null
}

# Sets the lifecycle policy that moves the exported data to the cold tier and then deletes it.
function Set-StorageManagementPolicy {
  Write-Step "Storage lifecycle policy"
  $policy = @{
    rules = @(
      [ordered]@{
        name       = $LifecycleRuleName
        enabled    = $true
        type       = 'Lifecycle'
        definition = [ordered]@{
          filters = [ordered]@{
            blobTypes   = @('blockBlob')
            prefixMatch = @("$ExportContainer/$ExportRootPath")
          }
          actions = @{
            baseBlob = [ordered]@{
              tierToCold = @{ daysAfterModificationGreaterThan = $ColdTierAfterDays }
              delete     = @{ daysAfterModificationGreaterThan = $RetentionDays }
            }
          }
        }
      }
    )
  }
  Invoke-AzMutation -Body $policy -BodyArgument '--policy' -Arguments @(
    'storage', 'account', 'management-policy', 'create',
    '--account-name', $StorageAccount,
    '--resource-group', $ResourceGroup
  ) | Out-Null
}

# Creates or updates the daily FOCUS cost export on the billing account.
function Set-FocusCostExport {
  $exportResourceId = "/providers/Microsoft.Billing/billingAccounts/$BillingAccountId/providers/Microsoft.CostManagement/exports/$ExportName"
  $url = "${exportResourceId}?api-version=$CostManagementApiVersion"
  Write-Step "FOCUS cost export $ExportName"

  $existing = Invoke-Az -Arguments @('rest', '--method', 'GET', '--url', $url) -AllowFailure
  $scheduleStart = if ($existing -and $existing.properties.schedule.recurrencePeriod.from) {
    Format-UtcTimestamp $existing.properties.schedule.recurrencePeriod.from
  } else {
    Get-TomorrowUtc
  }

  $body = [ordered]@{
    location   = $Location
    identity   = @{ type = 'SystemAssigned' }
    properties = [ordered]@{
      format                = 'Parquet'
      compressionMode       = 'snappy'
      dataOverwriteBehavior = 'OverwritePreviousReport'
      partitionData         = $true
      definition            = [ordered]@{
        type      = 'FocusCost'
        timeframe = 'MonthToDate'
        dataSet   = [ordered]@{
          granularity   = 'Daily'
          configuration = @{ dataVersion = $ExportDataVersion }
        }
      }
      deliveryInfo          = @{
        destination = [ordered]@{
          type           = 'AzureBlob'
          resourceId     = $ExportStorageAccountId
          container      = $ExportContainer
          rootFolderPath = $ExportRootPath
        }
      }
      schedule              = [ordered]@{
        status           = 'Active'
        recurrence       = 'Daily'
        recurrencePeriod = [ordered]@{ from = $scheduleStart; to = $ExportScheduleEnd }
      }
    }
  }

  $export = Invoke-AzMutation -Arguments @('rest', '--method', 'PUT', '--url', $url) -Body $body -DryRunResult @{
    id       = $exportResourceId
    identity = @{ principalId = '<export-identity-principal-id>' }
  }
  $script:ExportId = $export.id
  $script:ExportPrincipalId = $export.identity.principalId
}

# Sets up the billing exports, and gives Infracost read access to the export container.
function Set-BillingExports {
  if ($SkipBillingExports) { return }

  if (-not $ExistingExport) {
    Register-ResourceProviders
    Set-ResourceGroup
    Set-StorageAccount
    Set-StorageContainer
    Set-StorageManagementPolicy
    Set-FocusCostExport

    Write-Step "Role Storage Blob Data Contributor on storage account for the cost export"
    Set-RoleAssignment -Scope $ExportStorageAccountId -Role 'Storage Blob Data Contributor' `
      -Description 'Infracost FOCUS cost export write access' -PrincipalId $ExportPrincipalId | Out-Null
  }

  $containerResourceId = "$ExportStorageAccountId/blobServices/default/containers/$ExportContainer"
  Write-Step "Role Storage Blob Data Reader on container $ExportContainer"
  Set-RoleAssignment -Scope $containerResourceId -Role 'Storage Blob Data Reader' `
    -Description 'Infracost read-only access to billing exports' -PrincipalId $ServicePrincipalObjectId | Out-Null

  $script:BillingExports = [ordered]@{
    storage_account_id = $ExportStorageAccountId
    container          = $ExportContainer
    root_path          = $ExportRootPath
    export_id          = $ExportId
  }
}

# Writes the values for Infracost to stdout as JSON.
function Write-Outputs {
  Write-Step "Values to provide to Infracost"
  [ordered]@{
    tenant_id                   = $ActiveTenantId
    service_principal_object_id = $ServicePrincipalObjectId
    management_group_ids        = $ManagementGroupIds
    role_assignment_ids         = $RoleAssignmentIds
    billing_role_assignment_id  = $BillingRoleAssignmentId
    billing_exports             = $BillingExports
  } | ConvertTo-Json -Depth 5
}

try {
  Assert-LocalTools
  Assert-Arguments
  Read-ClientConfig
  Read-ManagementGroups
  Read-ServicePrincipal
  Resolve-StorageAccountName
  Resolve-ExportDestination
  Confirm-BillingAccount
  Assert-StorageAccountOwner
  Invoke-Preflight
  Set-ServicePrincipal
  Set-ManagementGroupRoles
  Set-BillingAccess
  Set-BillingExports
  Write-Outputs
} finally {
  Remove-TemporaryFiles
}
