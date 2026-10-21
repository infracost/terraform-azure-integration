# Microsoft Customer Agreement: existing export

Set up Infracost with a FOCUS cost export that exists. The script does not create a storage account or a cost export. Infracost only gets read access to the container.

Billing permission: Billing account owner. See [Prerequisites](../../README.md#prerequisites).

Do a dry run first. Then run the same command without `--dry-run` in bash or `-DryRun` in PowerShell.

## Linux, macOS, WSL, Cloud Shell (bash)

```bash
./scripts/linux/setup.sh --dry-run \
  --client-id <infracost-client-id> \
  --tenant-id <tenant-id> \
  --billing-agreement-type MCA \
  --billing-account-id '<guid>:<guid>_<yyyy-mm-dd>' \
  --existing-export '/subscriptions/<id>/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/<name>,<container>,<root-path>'
```

## Windows (PowerShell)

```powershell
.\scripts\windows\setup.ps1 -DryRun `
  -ClientId <infracost-client-id> `
  -TenantId <tenant-id> `
  -BillingAgreementType MCA `
  -BillingAccountId '<guid>:<guid>_<yyyy-mm-dd>' `
  -ExistingExport '/subscriptions/<id>/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/<name>,<container>,<root-path>'
```
