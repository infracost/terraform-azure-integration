#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Options. See show_usage for a description of each option.
client_id=""
tenant_id=""
subscription=""
management_groups=""
roles="$DEFAULT_ROLES"
owners=""
billing_agreement_type=""
billing_account_id=""
skip_billing_access=false
location=""
resource_group="$DEFAULT_RESOURCE_GROUP"
storage_account=""
existing_export=""
skip_billing_exports=false
dry_run=false
skip_preflight=false

# IDs of the created items, for the output.
role_assignment_ids_json=""
billing_role_assignment_id=""
export_id=""
export_principal_id=""
billing_exports_json="null"

# Shows the help.
show_usage() {
  cat <<EOF
Usage: $(basename "$0") --client-id <guid> [options]

Sets up the Infracost Azure integration with the az CLI. Same result as the
terraform-azure-integration module. Safe to run more than once.

Required:
  --client-id <guid>                  Client ID of the Infracost multi-tenant application.

Tenant:
  --tenant-id <guid>                  Tenant to use. Fails if the az CLI is signed in to another tenant.
  --subscription <guid>               Subscription that hosts the billing exports. Default: az CLI default subscription.

Access:
  --management-groups <a,b>           Management group names. Default: tenant root management group.
  --roles <a,b>                       Roles on the management groups. Default: "${DEFAULT_ROLES}".
  --owners <oid,oid>                  Object IDs that own the service principal.

Billing access:
  --billing-agreement-type <EA|MCA>   Billing agreement of the billing account.
  --billing-account-id <id>           EA enrollment number or MCA billing account ID.
  --skip-billing-access               Do not assign the billing reader role.

Billing exports:
  --location <region>                 Region of the storage account and cost export.
  --resource-group <name>             Default: ${DEFAULT_RESOURCE_GROUP}.
  --storage-account <name>            Default: derived from the tenant ID. Must not exist, or must be created by setup.sh.
  --existing-export <storage_account_id,container,root_path>
                                      Use an existing FOCUS cost export. Only the blob reader role is assigned.
  --skip-billing-exports              Do not set up billing exports.

Other:
  --dry-run                           Print the changes. Do not apply them.
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
      --owners)
        owners="$(read_option_value "$@")"
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
      --location)
        location="$(read_option_value "$@")"
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
      --skip-billing-exports)
        skip_billing_exports=true
        shift
        ;;
      --dry-run)
        dry_run=true
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
  local owner
  management_groups="$(split_list_argument "$management_groups")"
  roles="$(split_list_argument "$roles")"
  owners="$(split_list_argument "$owners")"
  [[ "$client_id" =~ $GUID_PATTERN ]] || stop_with_error "--client-id must be a GUID."
  assert_tenant_and_subscription_arguments
  [ -n "$roles" ] || stop_with_error "--roles must contain at least one role."
  if [ "$skip_billing_exports" = false ] && [ -z "$existing_export" ] && [ -z "$location" ]; then
    stop_with_error "--location is required to create the billing exports."
  fi
  assert_billing_arguments
  [ -z "$existing_export" ] || read_existing_export
  assert_storage_account_name
  IFS=',' read -r -a owner_list <<<"$owners"
  for owner in ${owner_list[@]+"${owner_list[@]}"}; do
    [[ "$owner" =~ $GUID_PATTERN ]] || stop_with_error "--owners must contain object ID GUIDs."
  done
}

# Stops if the storage account exists and the setup script did not create it.
assert_storage_account_owner() {
  [ "$skip_billing_exports" = false ] && [ -z "$existing_export" ] || return 0
  test_resource_exists "$export_storage_account_id" || return 0
  [ -n "$(get_storage_account_version_tag)" ] \
    || stop_with_error "storage account ${storage_account} exists and does not have the ${VERSION_TAG_NAME} tag. Pass --storage-account with a different name, or use --existing-export."
}

# Stops if the billing account does not have the given billing agreement type.
confirm_billing_account() {
  local expected_agreement_type actual_agreement_type
  [ "$skip_billing_access" = false ] || return 0

  if [ "$billing_agreement_type" = EA ]; then
    expected_agreement_type="$EA_AGREEMENT_TYPE"
  else
    expected_agreement_type="$MCA_AGREEMENT_TYPE"
  fi

  actual_agreement_type="$(az rest --method GET \
    --url "/providers/Microsoft.Billing/billingAccounts/${billing_account_id}?api-version=${BILLING_API_VERSION}" \
    --query properties.agreementType -o tsv)" || stop_with_error "cannot read billing account ${billing_account_id}."
  [ "$actual_agreement_type" = "$expected_agreement_type" ] \
    || stop_with_error "--billing-agreement-type is ${billing_agreement_type}, but the billing account is ${actual_agreement_type}."
}

# Checks the permissions to register the resource providers and create the billing exports storage.
invoke_preflight_billing_exports_storage() {
  local namespace resource_group_scope name_available unregistered_resource_providers
  unregistered_resource_providers="$(get_unregistered_resource_providers)"
  for namespace in $unregistered_resource_providers; do
    assert_arm_actions "/subscriptions/${active_subscription_id}" "Resource provider registration" "${namespace}/register/action"
  done

  if test_resource_group_exists; then
    resource_group_scope="/subscriptions/${active_subscription_id}/resourceGroups/${resource_group}"
  else
    resource_group_scope="/subscriptions/${active_subscription_id}"
  fi
  assert_arm_actions "$resource_group_scope" "Billing exports storage" \
    Microsoft.Resources/subscriptions/resourceGroups/write \
    Microsoft.Storage/storageAccounts/write \
    Microsoft.Storage/storageAccounts/blobServices/containers/write \
    Microsoft.Storage/storageAccounts/managementPolicies/write \
    Microsoft.Authorization/roleAssignments/write

  test_resource_exists "$export_storage_account_id" && return 0
  if printf '%s\n' "$unregistered_resource_providers" | grep -qx Microsoft.Storage; then
    add_unchecked_permission "Storage account name: cannot check if ${storage_account} is available until the run registers Microsoft.Storage"
    return 0
  fi
  name_available="$(az storage account check-name --name "$storage_account" --query nameAvailable -o tsv 2>/dev/null || true)"
  case "$name_available" in
    true) add_preflight_pass "Storage account name ${storage_account} is available" ;;
    false) add_preflight_failure "Storage account name ${storage_account} is in use. Pass --storage-account with a different name" ;;
    *) add_unchecked_permission "Storage account name: cannot check if ${storage_account} is available" ;;
  esac
}

# Checks that the existing export storage account exists and that you can assign roles on it.
invoke_preflight_existing_export() {
  if test_resource_exists "$existing_storage_account_id"; then
    add_preflight_pass "Existing export: storage account ${existing_storage_account_id} exists"
    assert_arm_actions "$existing_storage_account_id" "Blob reader role on the existing export" \
      Microsoft.Authorization/roleAssignments/write
  else
    add_preflight_failure "Existing export: storage account ${existing_storage_account_id} not found"
  fi
}

# Checks all permissions before the first change.
invoke_preflight() {
  [ "$skip_preflight" = false ] || {
    write_step "Skipping preflight"
    return 0
  }
  write_step "Preflight"

  assert_service_principal_management "Service principal" "$service_principal_object_id"
  assert_management_group_role_permissions \
    Microsoft.Authorization/roleAssignments/read Microsoft.Authorization/roleAssignments/write
  [ "$skip_billing_access" = true ] \
    || assert_billing_actions "Billing reader role" Microsoft.Billing/billingAccounts/billingRoleAssignments/write

  if [ "$skip_billing_exports" = false ] && [ -n "$existing_export" ]; then
    invoke_preflight_existing_export
  elif [ "$skip_billing_exports" = false ]; then
    invoke_preflight_billing_exports_storage
    assert_billing_actions "FOCUS cost export" \
      Microsoft.CostManagement/exports/read Microsoft.CostManagement/exports/write
  fi

  write_preflight_report
}

# Creates the Infracost service principal if it does not exist, and sets its tags and owners.
set_service_principal() {
  local owner existing_owner_ids tags_body owner_body
  write_step "Service principal for application ${client_id}"

  if [ -z "$service_principal_object_id" ]; then
    service_principal_object_id="$(invoke_az_mutation --dry-run-result "<service-principal-object-id>" \
      ad sp create --id "$client_id" --query id -o tsv)"
  fi

  tags_body="$(
    cat <<EOF
{
  "tags": [
    "WindowsAzureActiveDirectoryIntegratedApp",
    "${VERSION_TAG_NAME}:${SCRIPT_VERSION}"
  ]
}
EOF
  )"
  invoke_az_mutation rest --method PATCH \
    --url "${GRAPH_URL}/servicePrincipals/${service_principal_object_id}" \
    --headers "Content-Type=application/json" \
    --body "$tags_body" >/dev/null

  [ -n "$owners" ] || return 0
  existing_owner_ids="$(az rest --method GET \
    --url "${GRAPH_URL}/servicePrincipals/${service_principal_object_id}/owners?\$select=id" \
    --query "value[].id" -o tsv 2>/dev/null || true)"
  for owner in "${owner_list[@]}"; do
    grep -qx "$owner" <<<"$existing_owner_ids" && continue
    owner_body="$(
      cat <<EOF
{
  "@odata.id": "${GRAPH_URL}/directoryObjects/${owner}"
}
EOF
    )"
    invoke_az_mutation rest --method POST \
      --url "${GRAPH_URL}/servicePrincipals/${service_principal_object_id}/owners/\$ref" \
      --headers "Content-Type=application/json" \
      --body "$owner_body" >/dev/null
  done
}

# Assigns a role to a principal on a scope, if the assignment does not exist. Returns the assignment ID.
set_role_assignment() {
  local scope="$1" role="$2" description="$3" principal_id="$4" assignment_id
  assignment_id="$(az role assignment list --assignee "$principal_id" --scope "$scope" --role "$role" \
    --query "[0].id" -o tsv 2>/dev/null || true)"
  if [ -z "$assignment_id" ]; then
    assignment_id="$(invoke_az_mutation --dry-run-result "<role-assignment-id>" \
      role assignment create --assignee-object-id "$principal_id" --assignee-principal-type ServicePrincipal \
      --role "$role" --scope "$scope" --description "$description" --query id -o tsv)" || return 1
  fi
  printf '%s\n' "$assignment_id"
}

# Assigns the read roles to Infracost on each management group.
set_management_group_roles() {
  local name scope role assignment_id
  IFS=',' read -r -a role_list <<<"$roles"
  while IFS='|' read -r name scope; do
    [ -n "$name" ] || continue
    for role in "${role_list[@]}"; do
      write_step "Role ${role} on management group ${name}"
      assignment_id="$(set_role_assignment "$scope" "$role" "Infracost read-only access" "$service_principal_object_id")" \
        || stop_with_error "cannot assign role ${role} on management group ${name}."
      role_assignment_ids_json="${role_assignment_ids_json:+${role_assignment_ids_json},}$(json_string "${name}/${role}"):$(json_string "$assignment_id")"
    done
  done <<<"$management_group_scopes"
}

# Assigns the billing reader role to Infracost on the billing account.
set_billing_access() {
  local billing_account_resource_id="/providers/Microsoft.Billing/billingAccounts/${billing_account_id}"
  local role_definition_id properties
  [ "$skip_billing_access" = false ] || return 0

  role_definition_id="$(get_billing_role_definition_id)"
  write_step "Billing reader role on billing account ${billing_account_id}"

  properties="$(
    cat <<EOF
{
    "principalId": "${service_principal_object_id}",
    "principalTenantId": "${active_tenant_id}",
    "roleDefinitionId": "${billing_account_resource_id}/billingRoleDefinitions/${role_definition_id}"
  }
EOF
  )"

  if [ "$billing_agreement_type" = EA ]; then
    set_enrollment_reader "$billing_account_resource_id" "$role_definition_id" "$properties"
  else
    set_billing_account_reader "$billing_account_resource_id" "$role_definition_id" "$properties"
  fi
}

# Assigns the EnrollmentReader role on an EA enrollment.
set_enrollment_reader() {
  local billing_account_resource_id="$1" role_definition_id="$2" properties="$3" assignment_name assignment_resource_id
  assignment_name="$(get_uuid_v5_url "${billing_account_resource_id}/${service_principal_object_id}/${role_definition_id}")"
  assignment_resource_id="${billing_account_resource_id}/billingRoleAssignments/${assignment_name}"
  billing_role_assignment_id="$(invoke_az_mutation --dry-run-result "$assignment_resource_id" \
    rest --method PUT --url "${assignment_resource_id}?api-version=${BILLING_API_VERSION}" \
    --body "{ \"properties\": ${properties} }" --query id -o tsv)"
}

# Assigns the billing account reader role on an MCA billing account, if the assignment does not exist.
set_billing_account_reader() {
  local billing_account_resource_id="$1" role_definition_id="$2" properties="$3" assignment_resource_id
  assignment_resource_id="${billing_account_resource_id}/billingRoleAssignments/${role_definition_id}_${service_principal_object_id}"
  billing_role_assignment_id="$(az rest --method GET \
    --url "${assignment_resource_id}?api-version=${BILLING_API_VERSION}" \
    --query id -o tsv 2>/dev/null || true)"
  [ -z "$billing_role_assignment_id" ] || return 0

  billing_role_assignment_id="$(invoke_az_mutation --dry-run-result "$assignment_resource_id" \
    rest --method POST --url "${billing_account_resource_id}/createBillingRoleAssignment?api-version=${BILLING_API_VERSION}" \
    --body "$properties" --query id -o tsv)"
}

# Registers the resource providers that the storage account and cost export need.
register_resource_providers() {
  local namespace
  for namespace in $(get_unregistered_resource_providers); do
    write_step "Resource provider ${namespace}"
    invoke_az_mutation provider register --namespace "$namespace" --subscription "$active_subscription_id" --wait >/dev/null
  done
}

# Creates the resource group of the storage account, if it does not exist.
set_resource_group() {
  write_step "Resource group ${resource_group}"
  test_resource_group_exists && return 0
  invoke_az_mutation group create --name "$resource_group" --location "$location" \
    --tags "${VERSION_TAG_NAME}=${SCRIPT_VERSION}" >/dev/null
}

# Creates the storage account for the cost export, if it does not exist.
set_storage_account() {
  write_step "Storage account ${storage_account}"
  az storage account show --name "$storage_account" --resource-group "$resource_group" \
    --query id -o tsv >/dev/null 2>&1 && return 0
  invoke_az_mutation storage account create --name "$storage_account" \
    --resource-group "$resource_group" --location "$location" \
    --sku "$STORAGE_ACCOUNT_SKU" --kind StorageV2 --min-tls-version TLS1_2 --https-only true \
    --allow-blob-public-access false --allow-shared-key-access false \
    --default-to-oauth-authentication true --tags "${VERSION_TAG_NAME}=${SCRIPT_VERSION}" >/dev/null
}

# Creates the blob container for the cost export, if it does not exist.
set_storage_container() {
  local container_exists
  write_step "Storage container ${export_container}"
  container_exists="$(az storage container-rm exists --storage-account "$export_storage_account_id" \
    --name "$export_container" --query exists -o tsv 2>/dev/null || true)"
  [ "$container_exists" != true ] || return 0
  invoke_az_mutation storage container-rm create --storage-account "$export_storage_account_id" \
    --name "$export_container" --public-access off >/dev/null
}

# Sets the lifecycle policy that moves the exported data to the cold tier and then deletes it.
set_storage_management_policy() {
  local policy
  write_step "Storage lifecycle policy"
  policy="$(
    cat <<EOF
{
  "rules": [
    {
      "name": "${LIFECYCLE_RULE_NAME}",
      "enabled": true,
      "type": "Lifecycle",
      "definition": {
        "filters": {
          "blobTypes": ["blockBlob"],
          "prefixMatch": ["${export_container}/${export_root_path}"]
        },
        "actions": {
          "baseBlob": {
            "tierToCold": { "daysAfterModificationGreaterThan": ${COLD_TIER_AFTER_DAYS} },
            "delete": { "daysAfterModificationGreaterThan": ${RETENTION_DAYS} }
          }
        }
      }
    }
  ]
}
EOF
  )"
  invoke_az_mutation storage account management-policy create --account-name "$storage_account" \
    --resource-group "$resource_group" --policy "$policy" >/dev/null
}

# Creates or updates the daily FOCUS cost export on the billing account.
set_focus_cost_export() {
  local export_resource_id url schedule_start body export_response
  export_resource_id="/providers/Microsoft.Billing/billingAccounts/${billing_account_id}/providers/Microsoft.CostManagement/exports/${EXPORT_NAME}"
  url="${export_resource_id}?api-version=${COST_MANAGEMENT_API_VERSION}"
  write_step "FOCUS cost export ${EXPORT_NAME}"

  schedule_start="$(az rest --method GET --url "$url" \
    --query properties.schedule.recurrencePeriod.from -o tsv 2>/dev/null || true)"
  [ -n "$schedule_start" ] || schedule_start="$(get_tomorrow_utc)"

  body="$(
    cat <<EOF
{
  "location": "${location}",
  "identity": { "type": "SystemAssigned" },
  "properties": {
    "format": "Parquet",
    "compressionMode": "snappy",
    "dataOverwriteBehavior": "OverwritePreviousReport",
    "partitionData": true,
    "definition": {
      "type": "FocusCost",
      "timeframe": "MonthToDate",
      "dataSet": {
        "granularity": "Daily",
        "configuration": { "dataVersion": "${EXPORT_DATA_VERSION}" }
      }
    },
    "deliveryInfo": {
      "destination": {
        "type": "AzureBlob",
        "resourceId": "${export_storage_account_id}",
        "container": "${export_container}",
        "rootFolderPath": "${export_root_path}"
      }
    },
    "schedule": {
      "status": "Active",
      "recurrence": "Daily",
      "recurrencePeriod": { "from": "${schedule_start}", "to": "${EXPORT_SCHEDULE_END}" }
    }
  }
}
EOF
  )"

  export_response="$(invoke_az_mutation --dry-run-result "${export_resource_id} <export-identity-principal-id>" \
    rest --method PUT --url "$url" --body "$body" \
    --query "join(' ', [id, identity.principalId])" -o tsv)"
  read -r export_id export_principal_id <<<"$export_response"
}

# Sets up the billing exports, and gives Infracost read access to the export container.
set_billing_exports() {
  local container_resource_id
  [ "$skip_billing_exports" = false ] || return 0

  if [ -z "$existing_export" ]; then
    register_resource_providers
    set_resource_group
    set_storage_account
    set_storage_container
    set_storage_management_policy
    set_focus_cost_export

    write_step "Role Storage Blob Data Contributor on storage account for the cost export"
    set_role_assignment "$export_storage_account_id" "Storage Blob Data Contributor" \
      "Infracost FOCUS cost export write access" "$export_principal_id" >/dev/null
  fi

  container_resource_id="${export_storage_account_id}/blobServices/default/containers/${export_container}"
  write_step "Role Storage Blob Data Reader on container ${export_container}"
  set_role_assignment "$container_resource_id" "Storage Blob Data Reader" \
    "Infracost read-only access to billing exports" "$service_principal_object_id" >/dev/null

  billing_exports_json="$(
    cat <<EOF
{
    "storage_account_id": $(json_string "$export_storage_account_id"),
    "container": $(json_string "$export_container"),
    "root_path": $(json_string "$export_root_path"),
    "export_id": $(json_string_or_null "$export_id")
  }
EOF
  )"
}

# Writes the values for Infracost to stdout as JSON.
write_outputs() {
  write_step "Values to provide to Infracost"
  cat <<EOF
{
  "tenant_id": $(json_string "$active_tenant_id"),
  "service_principal_object_id": $(json_string "$service_principal_object_id"),
  "management_group_ids": {${management_group_ids_json}},
  "role_assignment_ids": {${role_assignment_ids_json}},
  "billing_role_assignment_id": $(json_string_or_null "$billing_role_assignment_id"),
  "billing_exports": ${billing_exports_json}
}
EOF
}

# Runs the steps in order.
main() {
  read_arguments "$@"
  assert_local_tools
  assert_arguments
  read_client_config
  read_management_groups
  read_service_principal
  resolve_storage_account_name
  resolve_export_destination
  confirm_billing_account
  assert_storage_account_owner
  invoke_preflight
  set_service_principal
  set_management_group_roles
  set_billing_access
  set_billing_exports
  write_outputs
}

main "$@"
