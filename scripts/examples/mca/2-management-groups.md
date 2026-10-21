# Microsoft Customer Agreement: management groups

Set up Infracost for some management groups only.

Billing permission: Billing account owner. See [Prerequisites](../../README.md#prerequisites).

Do a dry run first. Then run the same command without `--dry-run` in bash or `-DryRun` in PowerShell.

## Linux, macOS, WSL, Cloud Shell (bash)

```bash
./scripts/linux/setup.sh --dry-run \
  --client-id <infracost-client-id> \
  --tenant-id <tenant-id> \
  --subscription <subscription-id> \
  --management-groups platform,workloads \
  --billing-agreement-type MCA \
  --billing-account-id '<guid>:<guid>_<yyyy-mm-dd>' \
  --location westeurope
```

## Windows (PowerShell)

```powershell
.\scripts\windows\setup.ps1 -DryRun `
  -ClientId <infracost-client-id> `
  -TenantId <tenant-id> `
  -Subscription <subscription-id> `
  -ManagementGroups platform, workloads `
  -BillingAgreementType MCA `
  -BillingAccountId '<guid>:<guid>_<yyyy-mm-dd>' `
  -Location westeurope
```
