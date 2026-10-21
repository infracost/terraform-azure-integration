# Enterprise Agreement: management groups

Set up Infracost for some management groups only.

Billing permission: Enterprise Administrator on the enrollment. See [Prerequisites](../../README.md#prerequisites).

Do a dry run first. Then run the same command without `--dry-run` in bash or `-DryRun` in PowerShell.

## Linux, macOS, WSL, Cloud Shell (bash)

```bash
./scripts/linux/setup.sh --dry-run \
  --client-id <infracost-client-id> \
  --tenant-id <tenant-id> \
  --subscription <subscription-id> \
  --management-groups platform,workloads \
  --billing-agreement-type EA \
  --billing-account-id 12345678 \
  --location westeurope
```

## Windows (PowerShell)

```powershell
.\scripts\windows\setup.ps1 -DryRun `
  -ClientId <infracost-client-id> `
  -TenantId <tenant-id> `
  -Subscription <subscription-id> `
  -ManagementGroups platform, workloads `
  -BillingAgreementType EA `
  -BillingAccountId 12345678 `
  -Location westeurope
```
