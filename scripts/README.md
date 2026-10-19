# setup.sh and teardown.sh

`setup.sh` sets up the Infracost Azure integration with the `az` CLI. It gives the same result as the Terraform module in this repository. Use it if you do not use Terraform.

`teardown.sh` removes what `setup.sh` created. It gives the same result as `terraform destroy`.

You can run each script more than once. `setup.sh` only creates the items that do not exist. `teardown.sh` only removes the items that exist.

Both scripts load `common.sh`. Keep the three files in the same directory.

## Prerequisites

- The [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli), signed in to the tenant to set up.
- The client ID of the Infracost application. Get it from the Infracost dashboard.
- These permissions for the principal that runs the script:

| Step | Permission |
| --- | --- |
| Service principal | Application Administrator, Cloud Application Administrator, or `Application.ReadWrite.All` |
| Management group roles | Owner or User Access Administrator on each management group |
| Billing role, EA | Enterprise Administrator on the enrollment |
| Billing role, MCA | Billing account owner |
| Billing exports | Owner on the subscription, and billing account access to create the cost export |

## Usage

Sign in and select the subscription that hosts the billing exports storage account:

```bash
az login --tenant <tenant-id>
az account set --subscription <subscription-id>
```

Pass `--tenant-id` and `--subscription` to make sure that the script uses this tenant and subscription. The script stops if the `az` CLI targets a different tenant or subscription. This is important when you can sign in to more than one tenant, for example as an Enterprise Agreement administrator with a different home tenant.

Do a dry run first. The script reads the current state and prints the changes, but does not apply them:

```bash
./scripts/setup.sh --dry-run \
  --client-id <infracost-client-id> \
  --tenant-id <tenant-id> \
  --subscription <subscription-id> \
  --billing-agreement-type MCA \
  --billing-account-id '<guid>:<guid>_<yyyy-mm-dd>' \
  --location westeurope
```

Then run the same command without `--dry-run`.

## Examples

Enterprise Agreement, all subscriptions in the tenant:

```bash
./scripts/setup.sh \
  --client-id <infracost-client-id> \
  --billing-agreement-type EA \
  --billing-account-id 12345678 \
  --location westeurope
```

Some management groups only:

```bash
./scripts/setup.sh \
  --client-id <infracost-client-id> \
  --management-groups platform,workloads \
  --billing-agreement-type MCA \
  --billing-account-id '<guid>:<guid>_<yyyy-mm-dd>' \
  --location westeurope
```

Use a FOCUS cost export that exists. The script only gives Infracost read access to the container:

```bash
./scripts/setup.sh \
  --client-id <infracost-client-id> \
  --skip-billing-access \
  --existing-export '/subscriptions/<id>/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/<name>,<container>,<root-path>'
```

No billing access and no billing exports:

```bash
./scripts/setup.sh \
  --client-id <infracost-client-id> \
  --skip-billing-access \
  --skip-billing-exports
```

## Options

| Option | Description | Default |
| --- | --- | --- |
| `--client-id <guid>` | Client ID of the Infracost Azure application. Required. | |
| `--tenant-id <guid>` | Tenant to use. The script stops if the `az` CLI targets a different tenant. | Not checked |
| `--subscription <guid>` | Subscription that hosts the billing exports. The script stops if the `az` CLI targets a different subscription. | Not checked |
| `--management-groups <a,b>` | Management groups where Infracost gets read access. | Tenant root management group |
| `--roles <a,b>` | Roles on the management groups. | `Reader,Cost Management Reader,Monitoring Reader` |
| `--owners <oid,oid>` | Object IDs that own the service principal. | No owners |
| `--billing-agreement-type <EA\|MCA>` | Billing agreement of the billing account. | |
| `--billing-account-id <id>` | EA enrollment number, or MCA billing account ID. | |
| `--skip-billing-access` | Do not assign the billing reader role. | |
| `--location <region>` | Region of the storage account and cost export. | |
| `--resource-group <name>` | Resource group of the storage account. | `infracost-billing-exports` |
| `--storage-account <name>` | Name of the storage account. | `infracost` + 15 characters from the tenant ID hash |
| `--existing-export <id,container,path>` | Use a FOCUS cost export that exists. | |
| `--skip-billing-exports` | Do not set up billing exports. | |
| `--dry-run` | Print the changes. Do not apply them. | |
| `--skip-preflight` | Do not check the permissions before the changes. | |

`--billing-agreement-type` and `--billing-account-id` are necessary, except with `--skip-billing-access`. `--billing-account-id` and `--location` are necessary to create the billing exports.

## Preflight

Before the first change, each script checks that the signed-in principal can do all the steps. The preflight also runs with `--dry-run`. If an item fails, the script lists all failed items and stops before it changes anything.

| Step | Check |
| --- | --- |
| Service principal | Graph directory role: Global Administrator, Application Administrator or Cloud Application Administrator. For a service principal that runs the script: `Application.ReadWrite.All`, or `Application.ReadWrite.OwnedBy` to create. Owner of the Infracost service principal is also accepted when it exists. |
| Management group roles | `Microsoft.Authorization/roleAssignments/read` and `/write` (`/delete` for teardown) on each management group |
| Billing reader role | Billing `checkAccess` on the billing account |
| Resource providers | `<namespace>/register/action` on the subscription, only for providers that are not registered |
| Billing exports storage | Write actions for the resource group, storage account, container, lifecycle policy and role assignments. Delete actions for teardown. |
| Storage account name | Name is free, if the storage account does not exist yet |
| FOCUS cost export | Billing `checkAccess` on the billing account |
| Existing export | Storage account exists, and `roleAssignments/write` on it |

The preflight cannot find these problems, so the run can still fail on them:

- Conditions on role assignments that limit which roles you can assign.
- Deny assignments.
- Custom directory roles that allow you to create a service principal. The preflight reports them as missing. Use `--skip-preflight`.
- Roles that you received a few minutes before the run, because Azure takes time to apply them.

If the preflight cannot read a permission, it shows a warning and does not stop. A role that is eligible in Privileged Identity Management, but not active, is reported as missing. Activate it and run the script again.

## Output

The script writes its progress to stderr, and the values for Infracost to stdout as JSON. Give these values to the Infracost dashboard:

```json
{
  "tenant_id": "...",
  "service_principal_object_id": "...",
  "management_group_ids": { "<name>": "/providers/Microsoft.Management/managementGroups/<name>" },
  "role_assignment_ids": { "<name>/Reader": "..." },
  "billing_role_assignment_id": "...",
  "billing_exports": {
    "storage_account_id": "...",
    "container": "infracost-exports",
    "root_path": "focus-cost",
    "export_id": "..."
  }
}
```

The keys are the same as the Terraform module outputs. To keep the values only:

```bash
./scripts/setup.sh ... > infracost-azure.json
```

## What the script creates

| Step | Terraform resource |
| --- | --- |
| Service principal of the Infracost application, with tags and owners | `azuread_service_principal.infracost` |
| Roles on each management group | `azurerm_role_assignment.infracost` |
| EnrollmentReader on the EA enrollment | `module.billing_access.azapi_resource.enrollment_reader` |
| Billing account reader on the MCA billing account | `module.billing_access.azapi_resource_action.billing_account_reader` |
| Registration of the Storage and Cost Management resource providers | `module.billing_exports.azapi_resource_action.resource_provider_registration` |
| Resource group | `module.billing_exports.azurerm_resource_group.billing_exports` |
| Storage account | `module.billing_exports.azurerm_storage_account.billing_exports` |
| Blob container | `module.billing_exports.azurerm_storage_container.billing_exports` |
| Lifecycle policy: cold tier after 90 days, delete after 365 days | `module.billing_exports.azurerm_storage_management_policy.billing_exports` |
| Daily FOCUS cost export | `module.billing_exports.azapi_resource.focus_cost_export` |
| Storage Blob Data Contributor for the cost export | `module.billing_exports.azurerm_role_assignment.export_blob_writer` |
| Storage Blob Data Reader for Infracost on the container | `module.billing_exports.azurerm_role_assignment.blob_reader` |

## Teardown

Run `teardown.sh` with the same options that you gave to `setup.sh`. The script removes the items in the reverse order. It asks for confirmation before it removes items.

```bash
./scripts/teardown.sh --dry-run \
  --client-id <infracost-client-id> \
  --billing-agreement-type MCA \
  --billing-account-id '<guid>:<guid>_<yyyy-mm-dd>'
```

Then run the same command without `--dry-run`. To run without a terminal, for example in CI, add `--yes`.

`teardown.sh` removes:

1. The Storage Blob Data Reader role of Infracost on the container.
2. The Storage Blob Data Contributor role of the cost export, and the FOCUS cost export.
3. The storage account, with its container, lifecycle policy and **all exported data**. Use `--keep-storage` to keep them.
4. The resource group, only if it has the `InfracostModuleVersion` tag from `setup.sh` and contains no other resources.
5. The billing reader role on the billing account.
6. The roles on each management group.
7. The service principal of the Infracost application in your tenant.

`teardown.sh` does not unregister the resource providers, because other resources in the subscription can use them. Terraform also keeps them registered.

With `--existing-export`, `teardown.sh` only removes the Storage Blob Data Reader role. The export and the storage account stay.

### Teardown options

`teardown.sh` accepts these options of `setup.sh`: `--client-id`, `--management-groups`, `--roles`, `--billing-agreement-type`, `--billing-account-id`, `--skip-billing-access`, `--resource-group`, `--storage-account`, `--existing-export`, `--skip-billing-exports` and `--dry-run`. It also accepts:

| Option | Description |
| --- | --- |
| `--keep-storage` | Keep the storage account and the exported data. |
| `--yes` | Do not ask for confirmation. |
| `--skip-preflight` | Do not check the permissions before the changes. |
