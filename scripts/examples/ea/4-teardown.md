# Enterprise Agreement: teardown

Remove what the `1-tenant-root` example created. The script asks for confirmation before it removes items. To run without a terminal, add `--yes` in bash or `-Yes` in PowerShell.

Billing permission: Enterprise Administrator on the enrollment. See [Prerequisites](../../README.md#prerequisites).

Do a dry run first. Then run the same command without `--dry-run` in bash or `-DryRun` in PowerShell.

## Linux, macOS, WSL, Cloud Shell (bash)

```bash
./scripts/linux/teardown.sh --dry-run \
  --client-id <infracost-client-id> \
  --tenant-id <tenant-id> \
  --subscription <subscription-id> \
  --billing-agreement-type EA \
  --billing-account-id 12345678
```

## Windows (PowerShell)

```powershell
.\scripts\windows\teardown.ps1 -DryRun `
  -ClientId <infracost-client-id> `
  -TenantId <tenant-id> `
  -Subscription <subscription-id> `
  -BillingAgreementType EA `
  -BillingAccountId 12345678
```
