# Microsoft Customer Agreement: tenant root

Set up Infracost for all subscriptions in the tenant. Infracost gets read access on the tenant root management group.

Billing permission: Billing account owner. See [Prerequisites](../../README.md#prerequisites).

Do a dry run first. Then run the same command without `--dry-run` in bash or `-DryRun` in PowerShell.

## Linux, macOS, WSL, Cloud Shell (bash)

```bash
./scripts/linux/setup.sh --dry-run \
  --client-id <infracost-client-id> \
  --tenant-id <tenant-id> \
  --subscription <subscription-id> \
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
  -BillingAgreementType MCA `
  -BillingAccountId '<guid>:<guid>_<yyyy-mm-dd>' `
  -Location westeurope
```
