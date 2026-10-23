<#
.SYNOPSIS
Removes the Infracost Azure integration that setup.ps1 created.

.DESCRIPTION
Gives the same result as terraform destroy on the terraform-azure-integration
module. Safe to run more than once: only the items that exist are removed.
Use the same parameters as for setup.ps1. Asks for confirmation before it
removes items.

.PARAMETER ClientId
Client ID of the Infracost multi-tenant application.

.PARAMETER TenantId
Tenant to use. Fails if the az CLI is signed in to another tenant.

.PARAMETER Subscription
Subscription that hosts the billing exports. Fails if the az CLI targets another subscription.

.PARAMETER ManagementGroups
Management group names where the roles are removed. Default: tenant root management group.

.PARAMETER Roles
Roles to remove from the management groups.

.PARAMETER Owners
Ignored. Accepted so that the parameters of setup.ps1 can be used.

.PARAMETER BillingAgreementType
Billing agreement of the billing account: EA or MCA.

.PARAMETER BillingAccountId
EA enrollment number, or MCA billing account ID.

.PARAMETER SkipBillingAccess
Do not remove the billing reader role.

.PARAMETER Location
Ignored. Accepted so that the parameters of setup.ps1 can be used.

.PARAMETER ResourceGroup
Resource group of the storage account.

.PARAMETER StorageAccount
Name of the storage account. Default: derived from the tenant ID.

.PARAMETER ExistingExport
Only remove the blob reader role on this FOCUS cost export, given as
<storage_account_id>,<container>,<root_path>.

.PARAMETER KeepStorage
Keep the storage account and the exported data.

.PARAMETER SkipBillingExports
Do not remove billing exports.

.PARAMETER DryRun
Print the changes. Do not apply them.

.PARAMETER Yes
Do not ask for confirmation.

.PARAMETER SkipPreflight
Do not check the permissions before the changes.

.EXAMPLE
.\teardown.ps1 -DryRun -ClientId <infracost-client-id> -BillingAgreementType EA -BillingAccountId 12345678

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
  [switch]$KeepStorage,
  [switch]$SkipBillingExports,
  [switch]$DryRun,
  [switch]$Yes,
  [switch]$SkipPreflight
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

# Stops if an option is missing or not valid.
function Assert-Arguments {
  $script:ManagementGroups = Split-ListArgument $ManagementGroups
  $script:Roles = Split-ListArgument $Roles
  if ($ClientId -notmatch $GuidPattern) { Stop-WithError "-ClientId must be a GUID." }
  Assert-TenantAndSubscriptionArguments
  if ($Roles.Count -eq 0) { Stop-WithError "-Roles must contain at least one role." }
  Assert-BillingArguments
  if ($ExistingExport) { Read-ExistingExport }
  Assert-StorageAccountName
}

# Asks for confirmation before the removal.
function Confirm-Teardown {
  if ($DryRun -or $Yes) { return }
  if ([Console]::IsInputRedirected) { Stop-WithError "pass -Yes to run without a terminal." }
  [Console]::Error.WriteLine()
  $prompt = if (-not $SkipBillingExports -and -not $ExistingExport -and -not $KeepStorage) {
    "This removes the Infracost integration from tenant $ActiveTenantId and deletes storage account $StorageAccount with all exported data. Continue? [y/N]"
  } else {
    "This removes the Infracost integration from tenant $ActiveTenantId. Continue? [y/N]"
  }
  $answer = Read-Host $prompt
  if ($answer -notin @('y', 'Y', 'yes')) { Stop-WithError "cancelled." }
}

# Checks the permissions to remove the cost export, the storage roles, the storage account and the resource group.
function Invoke-PreflightBillingExports {
  $removesStorage = -not $ExistingExport -and -not $KeepStorage

  if (-not $ExistingExport) {
    Assert-BillingAccountRole "FOCUS cost export"
  }

  if (Test-ResourceExists $ExportStorageAccountId) {
    Assert-ArmActions $ExportStorageAccountId "Billing exports storage roles" @(
      'Microsoft.Authorization/roleAssignments/read',
      'Microsoft.Authorization/roleAssignments/delete'
    )
    if ($removesStorage) {
      Assert-ArmActions $ExportStorageAccountId "Billing exports storage" @('Microsoft.Storage/storageAccounts/delete')
    }
  }

  if ($removesStorage -and (Test-ResourceGroupExists)) {
    Assert-ArmActions "/subscriptions/$ActiveSubscriptionId/resourceGroups/$ResourceGroup" "Billing exports resource group" @(
      'Microsoft.Resources/subscriptions/resourceGroups/delete'
    )
  }
}

# Checks all permissions before the first change.
function Invoke-Preflight {
  if ($SkipPreflight) { Write-Step "Skipping preflight"; return }
  Write-Step "Preflight"

  if ($ServicePrincipalObjectId) {
    Assert-ServicePrincipalManagement "Service principal" $ServicePrincipalObjectId
    Assert-ManagementGroupRolePermissions @('Microsoft.Authorization/roleAssignments/read', 'Microsoft.Authorization/roleAssignments/delete')
    if (-not $SkipBillingAccess) {
      Assert-BillingAccountRole "Billing reader role"
    }
  }

  if (-not $SkipBillingExports) { Invoke-PreflightBillingExports }

  Write-PreflightReport
}

# Removes the role assignments of a principal on a scope.
function Remove-RoleAssignments {
  param([string]$Scope, [string]$Role, [string]$PrincipalId)
  $removedCount = 0
  if ($PrincipalId) {
    $assignments = @(Invoke-Az -AllowFailure -Arguments @(
        'role', 'assignment', 'list',
        '--assignee', $PrincipalId,
        '--scope', $Scope,
        '--role', $Role
      ))
    foreach ($assignment in $assignments) {
      if (-not $assignment -or $assignment.scope -ne $Scope) { continue }
      Invoke-AzMutation -Arguments @('role', 'assignment', 'delete', '--ids', $assignment.id) | Out-Null
      $removedCount++
    }
  }
  if ($removedCount -eq 0) { Write-StepDetail "not found, skipping" }
}

# Removes the resource group, only if the setup script created it and it contains no other resources.
function Remove-ResourceGroup {
  Write-Step "Resource group $ResourceGroup"
  $group = Invoke-Az -Arguments @('group', 'show', '--name', $ResourceGroup) -AllowFailure
  if (-not $group -or -not $group.tags -or -not $group.tags.$VersionTagName) {
    Write-StepDetail "not found or not created by setup.ps1, skipping"
    return
  }

  $resources = @(Invoke-Az -Arguments @('resource', 'list', '--resource-group', $ResourceGroup))
  $remainingResourceCount = @($resources | Where-Object { $_ -and $_.id -ne $ExportStorageAccountId }).Count
  if ($remainingResourceCount -ne 0) {
    Write-StepDetail "has $remainingResourceCount other resources, skipping"
    return
  }

  Invoke-AzMutation -Arguments @('group', 'delete', '--name', $ResourceGroup, '--yes') | Out-Null
}

# Removes the storage roles, the cost export and the storage account.
function Remove-BillingExports {
  if ($SkipBillingExports) { return }

  $containerResourceId = "$ExportStorageAccountId/blobServices/default/containers/$ExportContainer"
  Write-Step "Role Storage Blob Data Reader on container $ExportContainer"
  Remove-RoleAssignments -Scope $containerResourceId -Role 'Storage Blob Data Reader' -PrincipalId $ServicePrincipalObjectId

  if ($ExistingExport) { return }

  $exportUrl = "/providers/Microsoft.Billing/billingAccounts/$BillingAccountId/providers/Microsoft.CostManagement/exports/${ExportName}?api-version=$CostManagementApiVersion"
  $export = Invoke-Az -Arguments @('rest', '--method', 'GET', '--url', $exportUrl) -AllowFailure
  $exportPrincipalId = if ($export) { $export.identity.principalId } else { '' }

  Write-Step "Role Storage Blob Data Contributor on storage account for the cost export"
  Remove-RoleAssignments -Scope $ExportStorageAccountId -Role 'Storage Blob Data Contributor' -PrincipalId $exportPrincipalId

  Write-Step "FOCUS cost export $ExportName"
  if ($export) {
    Invoke-AzMutation -Arguments @('rest', '--method', 'DELETE', '--url', $exportUrl) | Out-Null
  } else {
    Write-StepDetail "not found, skipping"
  }

  Write-Step "Storage account $StorageAccount"
  if ($KeepStorage) {
    Write-StepDetail "kept because of -KeepStorage, skipping"
    return
  }
  if (-not (Test-ResourceExists $ExportStorageAccountId)) {
    Write-StepDetail "not found, skipping"
  } elseif (-not (Get-StorageAccountVersionTag)) {
    Write-StepDetail "not created by setup.ps1, skipping"
    return
  } else {
    Invoke-AzMutation -Arguments @('storage', 'account', 'delete', '--ids', $ExportStorageAccountId, '--yes') | Out-Null
  }

  Remove-ResourceGroup

  Write-Step "Resource providers"
  Write-StepDetail "stay registered, skipping"
}

# Removes the billing reader role of Infracost on the billing account.
function Remove-BillingAccess {
  if ($SkipBillingAccess) { return }
  Write-Step "Billing reader role on billing account $BillingAccountId"
  if (-not $ServicePrincipalObjectId) {
    Write-StepDetail "service principal not found, skipping"
    return
  }

  $billingAccountResourceId = "/providers/Microsoft.Billing/billingAccounts/$BillingAccountId"
  $roleDefinitionId = Get-BillingRoleDefinitionId
  $assignmentName = if ($BillingAgreementType -eq 'EA') {
    Get-UuidV5Url "$billingAccountResourceId/$ServicePrincipalObjectId/$roleDefinitionId"
  } else {
    "${roleDefinitionId}_$ServicePrincipalObjectId"
  }
  $assignmentUrl = "$billingAccountResourceId/billingRoleAssignments/${assignmentName}?api-version=$BillingApiVersion"

  if (-not (Invoke-Az -Arguments @('rest', '--method', 'GET', '--url', $assignmentUrl) -AllowFailure)) {
    Write-StepDetail "not found, skipping"
    return
  }
  Invoke-AzMutation -Arguments @('rest', '--method', 'DELETE', '--url', $assignmentUrl) | Out-Null
}

# Removes the roles of Infracost on each management group.
function Remove-ManagementGroupRoles {
  foreach ($name in $ManagementGroupIds.Keys) {
    foreach ($role in $Roles) {
      Write-Step "Role $role on management group $name"
      Remove-RoleAssignments -Scope $ManagementGroupIds[$name] -Role $role -PrincipalId $ServicePrincipalObjectId
    }
  }
}

# Removes the Infracost service principal from the tenant.
function Remove-ServicePrincipal {
  Write-Step "Service principal for application $ClientId"
  if (-not $ServicePrincipalObjectId) {
    Write-StepDetail "not found, skipping"
    return
  }
  Invoke-AzMutation -Arguments @('ad', 'sp', 'delete', '--id', $ServicePrincipalObjectId) | Out-Null
}

try {
  Assert-LocalTools
  Assert-Arguments
  Read-ClientConfig
  Read-ManagementGroups
  Read-ServicePrincipal
  if (-not $ServicePrincipalObjectId) { Write-Step "Service principal for application $ClientId not found" }
  Resolve-StorageAccountName
  Resolve-ExportDestination
  Invoke-Preflight
  Confirm-Teardown
  Remove-BillingExports
  Remove-BillingAccess
  Remove-ManagementGroupRoles
  Remove-ServicePrincipal
  Write-Step "Done"
} finally {
  Remove-TemporaryFiles
}
