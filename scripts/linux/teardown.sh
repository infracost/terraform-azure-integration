#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Options. See show_usage for a description of each option.
client_id=""
tenant_id=""
subscription=""
management_groups=""
roles="$DEFAULT_ROLES"
billing_agreement_type=""
billing_account_id=""
skip_billing_access=false
resource_group="$DEFAULT_RESOURCE_GROUP"
storage_account=""
existing_export=""
keep_storage=false
skip_billing_exports=false
dry_run=false
yes=false
skip_preflight=false

# Shows the help.
show_usage() {
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
  --roles <a,b>                       Roles on the management groups. Default: "${DEFAULT_ROLES}".

Billing access:
  --billing-agreement-type <EA|MCA>   Billing agreement of the billing account.
  --billing-account-id <id>           EA enrollment number or MCA billing account ID.
  --skip-billing-access               Do not remove the billing reader role.

Billing exports:
  --resource-group <name>             Default: ${DEFAULT_RESOURCE_GROUP}.
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

# Reads the command-line options.
read_arguments() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --client-id)
        client_id="$(read_option_value "$@")"
        shift 2
        ;;
      --tenant-id)
        tenant_id="$(read_option_value "$@")"
        shift 2
        ;;
      --subscription)
        subscription="$(read_option_value "$@")"
        shift 2
        ;;
      --management-groups)
        management_groups="$(read_option_value "$@")"
        shift 2
        ;;
      --roles)
        roles="$(read_option_value "$@")"
        shift 2
        ;;
      --billing-agreement-type)
        billing_agreement_type="$(read_option_value "$@")"
        shift 2
        ;;
      --billing-account-id)
        billing_account_id="$(read_option_value "$@")"
        shift 2
        ;;
      --skip-billing-access)
        skip_billing_access=true
        shift
        ;;
      --location | --owners)
        read_option_value "$@" >/dev/null
        shift 2
        ;;
      --resource-group)
        resource_group="$(read_option_value "$@")"
        shift 2
        ;;
      --storage-account)
        storage_account="$(read_option_value "$@")"
        shift 2
        ;;
      --existing-export)
        existing_export="$(read_option_value "$@")"
        shift 2
        ;;
      --keep-storage)
        keep_storage=true
        shift
        ;;
      --skip-billing-exports)
        skip_billing_exports=true
        shift
        ;;
      --dry-run)
        dry_run=true
        shift
        ;;
      --yes)
        yes=true
        shift
        ;;
      --skip-preflight)
        skip_preflight=true
        shift
        ;;
      -h | --help)
        show_usage
        exit 0
        ;;
      *)
        show_usage >&2
        stop_with_error "unknown argument: $1"
        ;;
    esac
  done
}

# Stops if an option is missing or not valid.
assert_arguments() {
  management_groups="$(split_list_argument "$management_groups")"
  roles="$(split_list_argument "$roles")"
  [[ "$client_id" =~ $GUID_PATTERN ]] || stop_with_error "--client-id must be a GUID."
  assert_tenant_and_subscription_arguments
  [ -n "$roles" ] || stop_with_error "--roles must contain at least one role."
  assert_billing_arguments
  [ -z "$existing_export" ] || read_existing_export
  assert_storage_account_name
}

# Asks for confirmation before the removal.
confirm_teardown() {
  local answer
  [ "$dry_run" = false ] && [ "$yes" = false ] || return 0
  [ -t 0 ] || stop_with_error "pass --yes to run without a terminal."
  if [ "$skip_billing_exports" = false ] && [ -z "$existing_export" ] && [ "$keep_storage" = false ]; then
    printf 'This removes the Infracost integration from tenant %s and deletes storage account %s with all exported data. Continue? [y/N] ' \
      "$active_tenant_id" "$storage_account" >&2
  else
    printf 'This removes the Infracost integration from tenant %s. Continue? [y/N] ' "$active_tenant_id" >&2
  fi
  read -r answer
  case "$answer" in
    y | Y | yes) ;;
    *) stop_with_error "cancelled." ;;
  esac
}

# Checks the permissions to remove the cost export, the storage roles, the storage account and the resource group.
invoke_preflight_billing_exports() {
  local removes_storage=false
  [ -n "$existing_export" ] || [ "$keep_storage" = true ] || removes_storage=true

  [ -n "$existing_export" ] \
    || assert_billing_account_role "FOCUS cost export"

  if test_resource_exists "$export_storage_account_id"; then
    assert_arm_actions "$export_storage_account_id" "Billing exports storage roles" \
      Microsoft.Authorization/roleAssignments/read Microsoft.Authorization/roleAssignments/delete
    [ "$removes_storage" = false ] \
      || assert_arm_actions "$export_storage_account_id" "Billing exports storage" Microsoft.Storage/storageAccounts/delete
  fi

  if [ "$removes_storage" = true ] && test_resource_group_exists; then
    assert_arm_actions "/subscriptions/${active_subscription_id}/resourceGroups/${resource_group}" \
      "Billing exports resource group" Microsoft.Resources/subscriptions/resourceGroups/delete
  fi
}

# Checks all permissions before the first change.
invoke_preflight() {
  [ "$skip_preflight" = false ] || {
    write_step "Skipping preflight"
    return 0
  }
  write_step "Preflight"

  if [ -n "$service_principal_object_id" ]; then
    assert_service_principal_management "Service principal" "$service_principal_object_id"
    assert_management_group_role_permissions \
      Microsoft.Authorization/roleAssignments/read Microsoft.Authorization/roleAssignments/delete
    [ "$skip_billing_access" = true ] \
      || assert_billing_account_role "Billing reader role"
  fi

  [ "$skip_billing_exports" = true ] || invoke_preflight_billing_exports

  write_preflight_report
}

# Removes the role assignments of a principal on a scope.
remove_role_assignments() {
  local scope="$1" role="$2" principal_id="$3" assignment_id assignment_scope
  [ -n "$principal_id" ] || return 0
  while IFS=$'\t' read -r assignment_id assignment_scope; do
    [ -n "$assignment_id" ] || continue
    [ "$(lowercase "$assignment_scope")" = "$(lowercase "$scope")" ] || continue
    invoke_az_mutation role assignment delete --ids "$assignment_id"
  done < <(az role assignment list --assignee "$principal_id" --scope "$scope" --role "$role" \
    --query "[].[id, scope]" -o tsv 2>/dev/null || true)
}

# Removes the resource group, only if the setup script created it and it contains no other resources.
remove_resource_group() {
  local version_tag remaining_resource_count
  write_step "Resource group ${resource_group}"
  version_tag="$(az group show --name "$resource_group" \
    --query "tags.${VERSION_TAG_NAME}" -o tsv 2>/dev/null || true)"
  [ -n "$version_tag" ] || {
    write_step "Resource group not found or not created by setup.sh, skipping"
    return 0
  }

  remaining_resource_count="$(az resource list --resource-group "$resource_group" \
    --query "[?id!='${export_storage_account_id}'] | length(@)" -o tsv)"
  [ "$remaining_resource_count" = 0 ] || {
    write_step "Resource group has ${remaining_resource_count} other resources, skipping"
    return 0
  }

  invoke_az_mutation group delete --name "$resource_group" --yes
}

# Removes the storage roles, the cost export and the storage account.
remove_billing_exports() {
  local container_resource_id export_url export_id export_principal_id
  [ "$skip_billing_exports" = false ] || return 0

  container_resource_id="${export_storage_account_id}/blobServices/default/containers/${export_container}"
  write_step "Role Storage Blob Data Reader on container ${export_container}"
  remove_role_assignments "$container_resource_id" "Storage Blob Data Reader" "$service_principal_object_id"

  [ -z "$existing_export" ] || return 0

  export_url="/providers/Microsoft.Billing/billingAccounts/${billing_account_id}/providers/Microsoft.CostManagement/exports/${EXPORT_NAME}?api-version=${COST_MANAGEMENT_API_VERSION}"
  read -r export_id export_principal_id < <(az rest --method GET --url "$export_url" \
    --query "join(' ', [id, identity.principalId || ''])" -o tsv 2>/dev/null || true) || true

  write_step "Role Storage Blob Data Contributor on storage account for the cost export"
  remove_role_assignments "$export_storage_account_id" "Storage Blob Data Contributor" "$export_principal_id"

  write_step "FOCUS cost export ${EXPORT_NAME}"
  [ -z "$export_id" ] || invoke_az_mutation rest --method DELETE --url "$export_url"

  [ "$keep_storage" = false ] || {
    write_step "Keeping storage account ${storage_account}"
    return 0
  }

  write_step "Storage account ${storage_account}"
  if test_resource_exists "$export_storage_account_id"; then
    [ -n "$(get_storage_account_version_tag)" ] || {
      write_step "Storage account not created by setup.sh, skipping"
      return 0
    }
    invoke_az_mutation storage account delete --ids "$export_storage_account_id" --yes
  fi

  remove_resource_group

  write_step "Resource providers stay registered"
}

# Removes the billing reader role of Infracost on the billing account.
remove_billing_access() {
  local billing_account_resource_id="/providers/Microsoft.Billing/billingAccounts/${billing_account_id}"
  local role_definition_id assignment_name assignment_url
  [ "$skip_billing_access" = false ] || return 0
  [ -n "$service_principal_object_id" ] || return 0

  role_definition_id="$(get_billing_role_definition_id)"
  if [ "$billing_agreement_type" = EA ]; then
    assignment_name="$(get_uuid_v5_url "${billing_account_resource_id}/${service_principal_object_id}/${role_definition_id}")"
  else
    assignment_name="${role_definition_id}_${service_principal_object_id}"
  fi
  assignment_url="${billing_account_resource_id}/billingRoleAssignments/${assignment_name}?api-version=${BILLING_API_VERSION}"

  write_step "Billing reader role on billing account ${billing_account_id}"
  az rest --method GET --url "$assignment_url" --query id -o tsv >/dev/null 2>&1 || return 0
  invoke_az_mutation rest --method DELETE --url "$assignment_url"
}

# Removes the roles of Infracost on each management group.
remove_management_group_roles() {
  local name scope role
  IFS=',' read -r -a role_list <<<"$roles"
  while IFS='|' read -r name scope; do
    [ -n "$name" ] || continue
    for role in "${role_list[@]}"; do
      write_step "Role ${role} on management group ${name}"
      remove_role_assignments "$scope" "$role" "$service_principal_object_id"
    done
  done <<<"$management_group_scopes"
}

# Removes the Infracost service principal from the tenant.
remove_service_principal() {
  [ -n "$service_principal_object_id" ] || return 0
  write_step "Service principal for application ${client_id}"
  invoke_az_mutation ad sp delete --id "$service_principal_object_id"
}

# Runs the steps in order.
main() {
  read_arguments "$@"
  assert_local_tools
  assert_arguments
  read_client_config
  read_management_groups
  read_service_principal
  [ -n "$service_principal_object_id" ] || write_step "Service principal for application ${client_id} not found"
  resolve_storage_account_name
  resolve_export_destination
  invoke_preflight
  confirm_teardown
  remove_billing_exports
  remove_billing_access
  remove_management_group_roles
  remove_service_principal
  write_step "Done"
}

main "$@"
