# Version of the scripts. Set on each Azure item that the scripts create.
$ScriptVersion = '0.5.0' # x-release-please-version

# API versions and endpoints of the Azure REST APIs.
$BillingApiVersion = '2024-04-01'
$CostManagementApiVersion = '2025-03-01'
$PermissionsApiVersion = '2022-04-01'
$GraphUrl = 'https://graph.microsoft.com/v1.0'

# Billing agreement types and their billing reader role definitions.
$EaAgreementType = 'EnterpriseAgreement'
$EaRoleDefinitionId = '24f8edb6-1668-4659-b5e2-40bb5f3a7d7e'
$McaAgreementType = 'MicrosoftCustomerAgreement'
$McaRoleDefinitionId = '50000000-aaaa-bbbb-cccc-100000000002'

# Directory roles and Microsoft Graph application permissions that allow you to manage the Infracost service principal.
$GlobalAdministratorRoleTemplateId = '62e90394-69f5-4237-9190-012177145e10'
$ApplicationAdministratorRoleTemplateId = '9b895d92-2cd3-44c7-9d02-a6ac2d5ea5c3'
$CloudApplicationAdministratorRoleTemplateId = '158c047a-c907-4556-b7ef-446551a6b5f7'
$ApplicationManagerRoleTemplateIds = @(
  $GlobalAdministratorRoleTemplateId,
  $ApplicationAdministratorRoleTemplateId,
  $CloudApplicationAdministratorRoleTemplateId
)
$GraphApplicationReadWriteAllRoleId = '1bfefb4e-e0b5-418b-a88f-73c46d2cc8e9'
$GraphApplicationReadWriteOwnedByRoleId = '18a4783c-866b-4cc7-a460-3d5e5662c884'

# UUID namespace for the billing role assignment name, and the resource providers that the billing exports need.
$UuidUrlNamespaceHex = '6ba7b8119dad11d180b400c04fd430c8'
$RequiredResourceProviders = @('Microsoft.Storage', 'Microsoft.CostManagement', 'Microsoft.CostManagementExports')

# Names and settings of the items that the scripts create. Same values as the Terraform module.
$VersionTagName = 'InfracostModuleVersion'
$StorageAccountNamePrefix = 'infracost'
$StorageAccountSku = 'Standard_LRS'
$ContainerName = 'infracost-exports'
$RootPath = 'focus-cost'
$LifecycleRuleName = 'tierAndDeleteBillingExports'
$ColdTierAfterDays = 90
$RetentionDays = 365
$ExportName = 'InfracostDailyFocusExport'
$ExportDataVersion = '1.2-preview'
$ExportScheduleEnd = '2099-12-31T00:00:00Z'

# Patterns to validate the options.
$GuidPattern = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
$BillingAccountIdPattern = '^([0-9]+|[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}:[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}_[0-9]{4}-[0-9]{2}-[0-9]{2})$'
$StorageAccountNamePattern = '^[a-z0-9]{3,24}$'
$StorageAccountIdPattern = '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Storage/storageAccounts/[^/]+$'
$ShellSafeArgumentPattern = '^[A-Za-z0-9_./:=@,+-]+$'

# State that the scripts read from Azure or calculate during the run.
$ActiveTenantId = ''
$ActiveSubscriptionId = ''
$SignedInPrincipalType = ''
$SignedInPrincipalName = ''
$ServicePrincipalObjectId = ''
$ManagementGroupIds = [ordered]@{}
$ExistingStorageAccountId = ''
$ExistingContainer = ''
$ExistingRootPath = ''
$ExportStorageAccountId = ''
$ExportContainer = ''
$ExportRootPath = ''
$PreflightFailures = New-Object System.Collections.Generic.List[string]
$PreflightUnchecked = New-Object System.Collections.Generic.List[string]
$TemporaryFiles = New-Object System.Collections.Generic.List[string]

# Writes a progress line to stderr.
function Write-Step {
  param([string]$Message)
  [Console]::Error.WriteLine("==> $Message")
}

# Writes an error to stderr and stops the script.
function Stop-WithError {
  param([string]$Message)
  Remove-TemporaryFiles
  [Console]::Error.WriteLine("error: $Message")
  exit 1
}

# Converts a value to single-line JSON.
function ConvertTo-CompactJson {
  param($Value)
  ConvertTo-Json -InputObject $Value -Depth 20 -Compress
}

# Writes a value to a temporary JSON file for an az request body.
function New-JsonFile {
  param($Value)
  $path = [IO.Path]::GetTempFileName()
  [IO.File]::WriteAllText($path, (ConvertTo-CompactJson $Value), (New-Object Text.UTF8Encoding $false))
  $TemporaryFiles.Add($path)
  $path
}

# Removes the temporary JSON files.
function Remove-TemporaryFiles {
  foreach ($path in $TemporaryFiles) {
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
  }
  $TemporaryFiles.Clear()
}

# Runs an az command that reads Azure and returns its JSON output.
function Invoke-Az {
  param(
    [string[]]$Arguments,
    $Body,
    [string]$BodyArgument = '--body',
    [switch]$AllowFailure
  )
  $azArguments = @($Arguments)
  if ($null -ne $Body) {
    $azArguments += @($BodyArgument, "@$(New-JsonFile $Body)")
  }
  $azArguments += @('--only-show-errors', '--output', 'json')

  $previousErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    if ($AllowFailure) {
      $output = & az @azArguments 2>$null
    } else {
      $output = & az @azArguments
    }
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorActionPreference
  }

  if ($exitCode -ne 0) {
    if ($AllowFailure) { return $null }
    Stop-WithError "az $(($Arguments | Select-Object -First 3) -join ' ') failed."
  }
  $text = ($output -join "`n").Trim()
  if (-not $text) { return }
  $parsed = ConvertFrom-Json -InputObject $text
  $parsed
}

# Formats an az command as a shell line that you can copy and run.
function Format-AzCommand {
  param([string[]]$Arguments)
  $formatted = foreach ($argument in $Arguments) {
    if ($argument -match $ShellSafeArgumentPattern) { $argument } else { "'" + $argument.Replace("'", "''") + "'" }
  }
  'az ' + ($formatted -join ' ')
}

# Runs an az command that changes Azure. With the dry run option, only prints it and returns the placeholder result.
function Invoke-AzMutation {
  param(
    [string[]]$Arguments,
    $Body,
    [string]$BodyArgument = '--body',
    $DryRunResult
  )
  $printed = @($Arguments)
  if ($null -ne $Body) { $printed += @($BodyArgument, (ConvertTo-CompactJson $Body)) }
  if ($DryRun) {
    [Console]::Error.WriteLine("[dry-run] $(Format-AzCommand $printed)")
    return $DryRunResult
  }
  [Console]::Error.WriteLine("[apply] $(Format-AzCommand $printed)")
  Invoke-Az -Arguments $Arguments -Body $Body -BodyArgument $BodyArgument
}

# Splits comma-separated values into a list.
function Split-ListArgument {
  param([string[]]$Values)
  @($Values | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# Formats a date as an ISO 8601 UTC timestamp.
function Format-UtcTimestamp {
  param($Value)
  if ($Value -is [DateTime]) {
    return $Value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
  }
  "$Value"
}

# Converts a hexadecimal string to bytes.
function ConvertFrom-HexString {
  param([string]$Hex)
  $bytes = New-Object byte[] ($Hex.Length / 2)
  for ($index = 0; $index -lt $bytes.Length; $index++) {
    $bytes[$index] = [Convert]::ToByte($Hex.Substring($index * 2, 2), 16)
  }
  , $bytes
}

# Calculates the SHA-1 hash as hexadecimal.
function Get-Sha1Hex {
  param([byte[]]$Bytes)
  $sha1 = [Security.Cryptography.SHA1]::Create()
  try {
    -join ($sha1.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') })
  } finally {
    $sha1.Dispose()
  }
}

# Calculates a name-based UUID (version 5). Gives the same billing role assignment name as the Terraform module.
function Get-UuidV5Url {
  param([string]$Name)
  $data = [byte[]]((ConvertFrom-HexString $UuidUrlNamespaceHex) + [Text.Encoding]::UTF8.GetBytes($Name))
  $hash = ConvertFrom-HexString (Get-Sha1Hex $data)
  $hash[6] = ($hash[6] -band 0x0f) -bor 0x50
  $hash[8] = ($hash[8] -band 0x3f) -bor 0x80
  $hex = -join ($hash[0..15] | ForEach-Object { $_.ToString('x2') })
  '{0}-{1}-{2}-{3}-{4}' -f $hex.Substring(0, 8), $hex.Substring(8, 4), $hex.Substring(12, 4), $hex.Substring(16, 4), $hex.Substring(20, 12)
}

# Gets the start of tomorrow in UTC, for the first run of the cost export.
function Get-TomorrowUtc {
  [DateTime]::UtcNow.Date.AddDays(1).ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) + 'T00:00:00Z'
}

# Stops if a necessary local tool is missing.
function Assert-LocalTools {
  if ($PSVersionTable.PSVersion -lt [version]'5.1') {
    Stop-WithError "PowerShell 5.1 or later is required."
  }
  if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Stop-WithError "az CLI not found."
  }
}

# Stops if the tenant or subscription value is not a GUID.
function Assert-TenantAndSubscriptionArguments {
  if ($TenantId -and $TenantId -notmatch $GuidPattern) { Stop-WithError "-TenantId must be a GUID." }
  if ($Subscription -and $Subscription -notmatch $GuidPattern) { Stop-WithError "-Subscription must be a GUID." }
}

# Stops if the billing agreement type or billing account ID is missing or not valid.
function Assert-BillingArguments {
  if (-not $SkipBillingAccess -and $BillingAgreementType -notin @('EA', 'MCA')) {
    Stop-WithError "-BillingAgreementType must be EA or MCA, or pass -SkipBillingAccess."
  }
  if (-not $SkipBillingAccess -or (-not $SkipBillingExports -and -not $ExistingExport)) {
    if (-not $BillingAccountId) { Stop-WithError "-BillingAccountId is required." }
    if ($BillingAccountId -notmatch $BillingAccountIdPattern) {
      Stop-WithError "-BillingAccountId must be an EA enrollment number or an MCA billing account ID."
    }
  }
}

# Stops if the storage account name is not valid.
function Assert-StorageAccountName {
  if ($StorageAccount -and $StorageAccount -cnotmatch $StorageAccountNamePattern) {
    Stop-WithError "-StorageAccount must be 3 to 24 lowercase letters and numbers."
  }
}

# Reads the storage account, container and path of the existing export, and stops if a value is not valid.
function Read-ExistingExport {
  $parts = @($ExistingExport -split ',', 3)
  $script:ExistingStorageAccountId = $parts[0]
  $script:ExistingContainer = if ($parts.Length -gt 1) { $parts[1] } else { '' }
  $script:ExistingRootPath = if ($parts.Length -gt 2) { $parts[2] } else { '' }
  if ($ExistingStorageAccountId -notmatch $StorageAccountIdPattern) {
    Stop-WithError "-ExistingExport storage_account_id must be a storage account resource ID."
  }
  if (-not $ExistingContainer -or -not $ExistingRootPath) {
    Stop-WithError "-ExistingExport must be <storage_account_id>,<container>,<root_path>."
  }
}

# Reads the tenant, subscription and principal of the az CLI, and stops if they are not the expected ones.
function Read-ClientConfig {
  $account = Invoke-Az -Arguments @('account', 'show') -AllowFailure
  if ($null -eq $account) {
    $tenantArgument = if ($TenantId) { " --tenant $TenantId" } else { '' }
    Stop-WithError "run 'az login$tenantArgument' first."
  }
  $script:ActiveTenantId = $account.tenantId
  $script:ActiveSubscriptionId = $account.id
  $script:SignedInPrincipalType = $account.user.type
  $script:SignedInPrincipalName = $account.user.name

  if ($TenantId -and $ActiveTenantId -ne $TenantId) {
    Stop-WithError "the az CLI targets tenant $ActiveTenantId, but -TenantId is $TenantId. Run 'az login --tenant $TenantId'."
  }
  if ($Subscription -and $ActiveSubscriptionId -ne $Subscription) {
    Stop-WithError "the az CLI targets subscription $ActiveSubscriptionId, but -Subscription is $Subscription. Run 'az account set --subscription $Subscription'."
  }

  Write-Step "Tenant $ActiveTenantId, subscription $ActiveSubscriptionId"
}

# Gets the resource ID of each management group. Uses the tenant root management group if no group is given.
function Read-ManagementGroups {
  $names = if ($ManagementGroups) { @($ManagementGroups) } else { @($ActiveTenantId) }
  foreach ($name in $names) {
    $managementGroup = Invoke-Az -Arguments @('account', 'management-group', 'show', '--name', $name) -AllowFailure
    if (-not $managementGroup) { Stop-WithError "management group $name not found." }
    $ManagementGroupIds[$name] = $managementGroup.id
  }
}

# Gets the object ID of the Infracost service principal, if it exists in the tenant.
function Read-ServicePrincipal {
  $servicePrincipal = Invoke-Az -Arguments @('ad', 'sp', 'show', '--id', $ClientId) -AllowFailure
  $script:ServicePrincipalObjectId = if ($servicePrincipal) { $servicePrincipal.id } else { '' }
}

# Calculates the storage account name from the tenant ID, if no name is given.
function Resolve-StorageAccountName {
  if ($StorageAccount) { return }
  $hash = Get-Sha1Hex ([Text.Encoding]::UTF8.GetBytes($ActiveTenantId))
  $script:StorageAccount = $StorageAccountNamePrefix + $hash.Substring(0, 15)
}

# Sets the storage account, container and path where the cost export writes.
function Resolve-ExportDestination {
  if ($ExistingExport) {
    $script:ExportStorageAccountId = $ExistingStorageAccountId
    $script:ExportContainer = $ExistingContainer
    $script:ExportRootPath = $ExistingRootPath
  } else {
    $script:ExportStorageAccountId = "/subscriptions/$ActiveSubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Storage/storageAccounts/$StorageAccount"
    $script:ExportContainer = $ContainerName
    $script:ExportRootPath = $RootPath
  }
}

# Gets the billing reader role for the billing agreement type.
function Get-BillingRoleDefinitionId {
  if ($BillingAgreementType -eq 'EA') { $EaRoleDefinitionId } else { $McaRoleDefinitionId }
}

# Lists the necessary resource providers that are not registered on the subscription.
function Get-UnregisteredResourceProviders {
  foreach ($namespace in $RequiredResourceProviders) {
    $provider = Invoke-Az -AllowFailure -Arguments @(
      'provider', 'show',
      '--namespace', $namespace,
      '--subscription', $ActiveSubscriptionId
    )
    if (-not $provider -or $provider.registrationState -ne 'Registered') { $namespace }
  }
}

# Checks if the resource group exists.
function Test-ResourceGroupExists {
  (Invoke-Az -Arguments @('group', 'exists', '--name', $ResourceGroup) -AllowFailure) -eq $true
}

# Checks if an Azure resource exists.
function Test-ResourceExists {
  param([string]$ResourceId)
  $null -ne (Invoke-Az -Arguments @('resource', 'show', '--ids', $ResourceId) -AllowFailure)
}

# Gets the version tag of the export storage account. Empty if the account does not exist or the setup script did not create it.
function Get-StorageAccountVersionTag {
  $account = Invoke-Az -Arguments @('storage', 'account', 'show', '--ids', $ExportStorageAccountId) -AllowFailure
  if ($account -and $account.tags) { $account.tags.$VersionTagName } else { '' }
}

# Records a permission that is missing.
function Add-PreflightFailure {
  param([string]$Message)
  $PreflightFailures.Add($Message)
}

# Records a permission that the preflight cannot check.
function Add-UncheckedPermission {
  param([string]$Message)
  $PreflightUnchecked.Add($Message)
}

# Checks if an action matches one of the action patterns, with * as a wildcard.
function Test-ActionMatchesAny {
  param([string]$Action, [string[]]$Patterns)
  foreach ($pattern in $Patterns) {
    if (-not $pattern) { continue }
    $patternRegex = '^' + [regex]::Escape($pattern).Replace('\*', '.*') + '$'
    if ($Action -match $patternRegex) { return $true }
  }
  $false
}

# Checks if the permissions allow an action and do not deny it.
function Test-ArmActionAllowed {
  param([string]$Action, $PermissionEntries)
  foreach ($entry in @($PermissionEntries)) {
    if (-not (Test-ActionMatchesAny $Action @($entry.actions))) { continue }
    if (Test-ActionMatchesAny $Action @($entry.notActions)) { continue }
    return $true
  }
  $false
}

# Checks that the signed-in principal can do each Azure action on a scope.
function Assert-ArmActions {
  param([string]$Scope, [string]$Description, [string[]]$Actions)
  $permissionsUrl = "$Scope/providers/Microsoft.Authorization/permissions?api-version=$PermissionsApiVersion"
  $permissions = Invoke-Az -Arguments @('rest', '--method', 'GET', '--url', $permissionsUrl) -AllowFailure
  if ($null -eq $permissions) {
    Add-UncheckedPermission "${Description}: cannot read the permissions on $Scope"
    return
  }
  foreach ($action in $Actions) {
    if (-not (Test-ArmActionAllowed $action $permissions.value)) {
      Add-PreflightFailure "${Description}: $action on $Scope"
    }
  }
}

# Checks that the signed-in principal can do each billing action on the billing account.
function Assert-BillingActions {
  param([string]$Description, [string[]]$Actions)
  $checkAccessUrl = "/providers/Microsoft.Billing/billingAccounts/$BillingAccountId/checkAccess?api-version=$BillingApiVersion"
  $accessDecisions = Invoke-Az -AllowFailure -Arguments @('rest', '--method', 'POST', '--url', $checkAccessUrl) -Body @{
    actions = @($Actions)
  }
  if ($null -eq $accessDecisions) {
    Add-UncheckedPermission "${Description}: cannot check access on billing account $BillingAccountId"
    return
  }
  foreach ($action in $Actions) {
    $decision = @($accessDecisions) | Where-Object { $_.action -eq $action } | Select-Object -First 1
    $accessDecision = if ($decision) { $decision.accessDecision } else { '' }
    switch ($accessDecision) {
      'Allowed' { }
      'NotAllowed' { Add-PreflightFailure "${Description}: $action on billing account $BillingAccountId" }
      default { Add-UncheckedPermission "${Description}: no access decision for $action on billing account $BillingAccountId" }
    }
  }
}

# Checks that the signed-in principal can create or change the Infracost service principal.
function Assert-ServicePrincipalManagement {
  param([string]$Description, [string]$TargetObjectId)
  if ($SignedInPrincipalType -eq 'servicePrincipal') {
    $callerPath = "$GraphUrl/servicePrincipals(appId='$SignedInPrincipalName')"
    $grants = Invoke-Az -Arguments @('rest', '--method', 'GET', '--url', "$callerPath/appRoleAssignments?`$select=appRoleId") -AllowFailure
    if ($null -ne $grants) {
      $grantedAppRoleIds = @($grants.value | ForEach-Object { $_.appRoleId })
      if ($grantedAppRoleIds -contains $GraphApplicationReadWriteAllRoleId) { return }
      if (-not $TargetObjectId -and $grantedAppRoleIds -contains $GraphApplicationReadWriteOwnedByRoleId) { return }
    }
  } else {
    $callerPath = "$GraphUrl/me"
  }

  $directoryRolesUrl = "$callerPath/transitiveMemberOf/microsoft.graph.directoryRole?`$select=roleTemplateId"
  $directoryRoles = Invoke-Az -Arguments @('rest', '--method', 'GET', '--url', $directoryRolesUrl) -AllowFailure
  if ($null -eq $directoryRoles) {
    Add-UncheckedPermission "${Description}: cannot read the directory roles of the signed-in principal"
    return
  }
  $roleTemplateIds = @($directoryRoles.value | ForEach-Object { $_.roleTemplateId })
  if (@($roleTemplateIds | Where-Object { $ApplicationManagerRoleTemplateIds -contains $_ }).Count -gt 0) { return }

  if ($TargetObjectId) {
    $caller = Invoke-Az -Arguments @('rest', '--method', 'GET', '--url', "${callerPath}?`$select=id") -AllowFailure
    $ownersUrl = "$GraphUrl/servicePrincipals/$TargetObjectId/owners?`$select=id"
    $owners = Invoke-Az -Arguments @('rest', '--method', 'GET', '--url', $ownersUrl) -AllowFailure
    $ownerIds = @($owners.value | ForEach-Object { $_.id })
    if ($caller -and $ownerIds -contains $caller.id) { return }
  }

  Add-PreflightFailure "${Description}: Application Administrator, Cloud Application Administrator or Global Administrator directory role, Application.ReadWrite.All, or ownership of the service principal"
}

# Checks the role assignment permissions on each management group.
function Assert-ManagementGroupRolePermissions {
  param([string[]]$Actions)
  foreach ($scope in $ManagementGroupIds.Values) {
    Assert-ArmActions -Scope $scope -Description "Management group roles" -Actions $Actions
  }
}

# Writes the preflight result. Stops if a permission is missing.
function Write-PreflightReport {
  if ($PreflightUnchecked.Count -gt 0) {
    Write-Step "Preflight could not check these items. The run can still fail on them:"
    foreach ($item in $PreflightUnchecked) { [Console]::Error.WriteLine("  - $item") }
  }
  if ($PreflightFailures.Count -eq 0) {
    Write-Step "Preflight passed"
    return
  }
  Write-Step "Preflight failed:"
  foreach ($item in $PreflightFailures) { [Console]::Error.WriteLine("  - $item") }
  Stop-WithError "fix the items above, or pass -SkipPreflight."
}
