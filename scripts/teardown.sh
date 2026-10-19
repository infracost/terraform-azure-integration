#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

infracost_client_id=""
expected_tenant_id=""
expected_subscription_id=""
management_group_names=""
role_definition_names="Reader,Cost Management Reader,Monitoring Reader"
enable_top_level_billing_access=true
billing_agreement_type=""
billing_account_id=""
enable_billing_exports=true
existing_export=""
billing_exports_resource_group_name="infracost-billing-exports"
billing_exports_storage_account_name=""
billing_exports_container_name="infracost-exports"
billing_exports_export_name="InfracostDailyFocusExport"
keep_storage=false
assume_yes=false
skip_preflight=false
dry_run=false

usage() {
  cat <<EOF
Usage: $(basename "$0") --client-id <guid> [options]

Removes the Infracost Azure integration that setup.sh created. Same result as
terraform destroy on the terraform-azure-integration module. Safe to run more
than once. Use the same options as for setup.sh.

Required:
  --client-id <guid>                  Client ID of the Infracost multi-tenant application.

Tenant:
  --tenant-id <guid>                  Tenant to use. Fails if the az CLI is signed in to another tenant.
  --subscription <guid>               Subscription that hosts the billing exports. Default: az CLI default subscription.

Access:
  --management-groups <a,b>           Management group names. Default: tenant root management group.
  --roles <a,b>                       Roles on the management groups. Default: "${role_definition_names}".

Billing access:
  --billing-agreement-type <EA|MCA>   Billing agreement of the billing account.
  --billing-account-id <id>           EA enrollment number or MCA billing account ID.
  --skip-billing-access               Do not remove the billing reader role.

Billing exports:
  --resource-group <name>             Default: ${billing_exports_resource_group_name}.
  --storage-account <name>            Default: derived from the tenant ID.
  --existing-export <storage_account_id,container,root_path>
                                      Only remove the blob reader role on this existing export.
  --keep-storage                      Keep the storage account and the exported data.
  --skip-billing-exports              Do not remove billing exports.

Other:
  --dry-run                           Print the changes. Do not apply them.
  --yes                               Do not ask for confirmation.
  --skip-preflight                    Do not check the permissions before the changes.
  -h, --help                          Show this help.
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --client-id) infracost_client_id="$2"; shift 2 ;;
      --tenant-id) expected_tenant_id="$2"; shift 2 ;;
      --subscription) expected_subscription_id="$2"; shift 2 ;;
      --management-groups) management_group_names="$2"; shift 2 ;;
      --roles) role_definition_names="$2"; shift 2 ;;
      --billing-agreement-type) billing_agreement_type="$2"; shift 2 ;;
      --billing-account-id) billing_account_id="$2"; shift 2 ;;
      --skip-billing-access) enable_top_level_billing_access=false; shift ;;
      --resource-group) billing_exports_resource_group_name="$2"; shift 2 ;;
      --storage-account) billing_exports_storage_account_name="$2"; shift 2 ;;
      --existing-export) existing_export="$2"; shift 2 ;;
      --keep-storage) keep_storage=true; shift ;;
      --skip-billing-exports) enable_billing_exports=false; shift ;;
      --dry-run) dry_run=true; shift ;;
      --yes) assume_yes=true; shift ;;
      --skip-preflight) skip_preflight=true; shift ;;
      -h | --help) usage; exit 0 ;;
      *) usage >&2; fail "unknown argument: $1" ;;
    esac
  done
}

validate_args() {
  [[ "$infracost_client_id" =~ $GUID_PATTERN ]] || fail "--client-id must be a GUID."
  validate_tenant_and_subscription_args
  [[ "$role_definition_names" =~ [^,[:space:]] ]] || fail "--roles must contain at least one role."

  if [ "$enable_top_level_billing_access" = true ]; then
    case "$billing_agreement_type" in
      EA | MCA) ;;
      *) fail "--billing-agreement-type must be EA or MCA, or pass --skip-billing-access." ;;
    esac
  fi

  if [ "$enable_top_level_billing_access" = true ] || { [ "$enable_billing_exports" = true ] && [ -z "$existing_export" ]; }; then
    [ -n "$billing_account_id" ] || fail "--billing-account-id is required."
    [[ "$billing_account_id" =~ $BILLING_ACCOUNT_ID_PATTERN ]] \
      || fail "--billing-account-id must be an EA enrollment number or an MCA billing account ID."
  fi

  [ -z "$existing_export" ] || parse_existing_export
  validate_storage_account_name
}

confirm() {
  local answer
  [ "$dry_run" = false ] && [ "$assume_yes" = false ] || return 0
  [ -t 0 ] || fail "pass --yes to run without a terminal."
  printf 'This removes the Infracost integration from tenant %s. Continue? [y/N] ' "$tenant_id" >&2
  read -r answer
  case "$answer" in
    y | Y | yes) ;;
    *) fail "cancelled." ;;
  esac
}

preflight() {
  local name scope storage_account_id resource_group_scope
  [ "$skip_preflight" = false ] || { log "Skipping preflight"; return 0; }
  log "Preflight"

  if [ -n "$service_principal_object_id" ]; then
    require_service_principal_management "Service principal" "$service_principal_object_id"

    while IFS='|' read -r name scope; do
      [ -n "$name" ] || continue
      require_arm_actions "$scope" "Management group roles" \
        Microsoft.Authorization/roleAssignments/read Microsoft.Authorization/roleAssignments/delete
    done <<<"$management_group_scopes"

    if [ "$enable_top_level_billing_access" = true ]; then
      require_billing_actions "Billing reader role" \
        Microsoft.Billing/billingAccounts/billingRoleAssignments/delete
    fi
  fi

  [ "$enable_billing_exports" = true ] || { report_preflight; return 0; }

  if [ -n "$existing_export" ]; then
    storage_account_id="$existing_storage_account_id"
  else
    storage_account_id="$(created_storage_account_id)"
    require_billing_actions "FOCUS cost export" \
      Microsoft.CostManagement/exports/read Microsoft.CostManagement/exports/delete
  fi

  if resource_exists "$storage_account_id"; then
    require_arm_actions "$storage_account_id" "Billing exports storage roles" \
      Microsoft.Authorization/roleAssignments/read Microsoft.Authorization/roleAssignments/delete
    if [ -z "$existing_export" ] && [ "$keep_storage" = false ]; then
      require_arm_actions "$storage_account_id" "Billing exports storage" Microsoft.Storage/storageAccounts/delete
    fi
  fi

  if [ -z "$existing_export" ] && [ "$keep_storage" = false ] && resource_group_exists; then
    resource_group_scope="/subscriptions/${subscription_id}/resourceGroups/${billing_exports_resource_group_name}"
    require_arm_actions "$resource_group_scope" "Billing exports resource group" \
      Microsoft.Resources/subscriptions/resourceGroups/delete
  fi

  report_preflight
}

delete_role_assignments() {
  local scope="$1" role="$2" principal_id="$3" assignment_id
  [ -n "$principal_id" ] || return 0
  while read -r assignment_id; do
    [ -n "$assignment_id" ] || continue
    mutate az role assignment delete --ids "$assignment_id" --only-show-errors
  done < <(az role assignment list --assignee "$principal_id" --scope "$scope" --role "$role" \
    --query "[?scope=='${scope}'].id" -o tsv 2>/dev/null || true)
}

# terraform: module.billing_exports (main.tf, export.tf, storage.tf)
remove_billing_exports() {
  local storage_account_id container_resource_id export_url export_principal_id
  [ "$enable_billing_exports" = true ] || return 0

  if [ -n "$existing_export" ]; then
    storage_account_id="$existing_storage_account_id"
    billing_exports_container_name="$existing_container"
  else
    storage_account_id="$(created_storage_account_id)"
  fi

  # terraform: module.billing_exports.azurerm_role_assignment.blob_reader
  container_resource_id="${storage_account_id}/blobServices/default/containers/${billing_exports_container_name}"
  log "Role Storage Blob Data Reader on container ${billing_exports_container_name}"
  delete_role_assignments "$container_resource_id" "Storage Blob Data Reader" "$service_principal_object_id"

  [ -z "$existing_export" ] || return 0

  export_url="/providers/Microsoft.Billing/billingAccounts/${billing_account_id}/providers/Microsoft.CostManagement/exports/${billing_exports_export_name}?api-version=${COST_MANAGEMENT_API_VERSION}"
  export_principal_id="$(az rest --method GET --url "$export_url" --query identity.principalId -o tsv 2>/dev/null || true)"

  # terraform: module.billing_exports.azurerm_role_assignment.export_blob_writer
  log "Role Storage Blob Data Contributor on storage account for the cost export"
  delete_role_assignments "$storage_account_id" "Storage Blob Data Contributor" "$export_principal_id"

  # terraform: module.billing_exports.azapi_resource.focus_cost_export, module.billing_exports.terraform_data.export_schedule_start
  log "FOCUS cost export ${billing_exports_export_name}"
  [ -z "$export_principal_id" ] || mutate az rest --method DELETE --url "$export_url"

  [ "$keep_storage" = false ] || { log "Keeping storage account ${billing_exports_storage_account_name}"; return 0; }

  # terraform: module.billing_exports.azurerm_storage_account.billing_exports, module.billing_exports.azurerm_storage_container.billing_exports, module.billing_exports.azurerm_storage_management_policy.billing_exports
  log "Storage account ${billing_exports_storage_account_name}"
  if az storage account show --ids "$storage_account_id" --query id -o tsv >/dev/null 2>&1; then
    mutate az storage account delete --ids "$storage_account_id" --yes --only-show-errors
  fi

  # terraform: module.billing_exports.azurerm_resource_group.billing_exports
  remove_resource_group

  # terraform: module.billing_exports.azapi_resource_action.resource_provider_registration
  log "Resource providers stay registered"
}

remove_resource_group() {
  local tagged remaining
  log "Resource group ${billing_exports_resource_group_name}"
  tagged="$(az group show --name "$billing_exports_resource_group_name" \
    --query "tags.InfracostModuleVersion" -o tsv 2>/dev/null || true)"
  [ -n "$tagged" ] || { log "Resource group not found or not created by setup.sh, skipping"; return 0; }

  remaining="$(az resource list --resource-group "$billing_exports_resource_group_name" \
    --query "[?id!='${storage_account_id}'] | length(@)" -o tsv)"
  [ "$remaining" = 0 ] || { log "Resource group has ${remaining} other resources, skipping"; return 0; }

  mutate az group delete --name "$billing_exports_resource_group_name" --yes --only-show-errors
}

# terraform: module.billing_access
remove_billing_access() {
  local billing_account_resource_id="/providers/Microsoft.Billing/billingAccounts/${billing_account_id}"
  local role_definition_id assignment_name assignment_url
  [ "$enable_top_level_billing_access" = true ] || return 0
  [ -n "$service_principal_object_id" ] || return 0

  role_definition_id="$(billing_role_definition_id)"
  if [ "$billing_agreement_type" = EA ]; then
    # terraform: module.billing_access.azapi_resource.enrollment_reader
    assignment_name="$(uuidv5_url "${billing_account_resource_id}/${service_principal_object_id}/${role_definition_id}")"
  else
    # terraform: module.billing_access.azapi_resource_action.billing_account_reader_removal
    assignment_name="${role_definition_id}_${service_principal_object_id}"
  fi
  assignment_url="${billing_account_resource_id}/billingRoleAssignments/${assignment_name}?api-version=${BILLING_API_VERSION}"

  log "Billing reader role on billing account ${billing_account_id}"
  az rest --method GET --url "$assignment_url" --query id -o tsv >/dev/null 2>&1 || return 0
  mutate az rest --method DELETE --url "$assignment_url"
}

# terraform: azurerm_role_assignment.infracost
remove_management_group_roles() {
  local name scope role
  IFS=',' read -r -a role_list <<<"$role_definition_names"
  while IFS='|' read -r name scope; do
    [ -n "$name" ] || continue
    for role in "${role_list[@]}"; do
      log "Role ${role} on management group ${name}"
      delete_role_assignments "$scope" "$role" "$service_principal_object_id"
    done
  done <<<"$management_group_scopes"
}

# terraform: azuread_service_principal.infracost
remove_service_principal() {
  [ -n "$service_principal_object_id" ] || return 0
  log "Service principal for application ${infracost_client_id}"
  mutate az ad sp delete --id "$service_principal_object_id" --only-show-errors
}

main() {
  parse_args "$@"
  validate_args
  read_client_config
  read_management_groups
  read_service_principal
  [ -n "$service_principal_object_id" ] || log "Service principal for application ${infracost_client_id} not found"
  resolve_storage_account_name
  preflight
  confirm
  remove_billing_exports
  remove_billing_access
  remove_management_group_roles
  remove_service_principal
  log "Done"
}

main "$@"
