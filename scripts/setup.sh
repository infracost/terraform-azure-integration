#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

infracost_client_id=""
expected_tenant_id=""
expected_subscription_id=""
management_group_names=""
role_definition_names="Reader,Cost Management Reader,Monitoring Reader"
service_principal_owners=""
enable_top_level_billing_access=true
billing_agreement_type=""
billing_account_id=""
enable_billing_exports=true
existing_export=""
billing_exports_location=""
billing_exports_resource_group_name="infracost-billing-exports"
billing_exports_storage_account_name=""
billing_exports_container_name="infracost-exports"
billing_exports_root_path="focus-cost"
billing_exports_export_name="InfracostDailyFocusExport"
cold_tier_after_days=90
retention_days=365
skip_preflight=false
dry_run=false

usage() {
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
  --roles <a,b>                       Roles on the management groups. Default: "${role_definition_names}".
  --owners <oid,oid>                  Object IDs that own the service principal.

Billing access:
  --billing-agreement-type <EA|MCA>   Billing agreement of the billing account.
  --billing-account-id <id>           EA enrollment number or MCA billing account ID.
  --skip-billing-access               Do not assign the billing reader role.

Billing exports:
  --location <region>                 Region of the storage account and cost export.
  --resource-group <name>             Default: ${billing_exports_resource_group_name}.
  --storage-account <name>            Default: derived from the tenant ID.
  --existing-export <storage_account_id,container,root_path>
                                      Use an existing FOCUS cost export. Only the blob reader role is assigned.
  --skip-billing-exports              Do not set up billing exports.

Other:
  --dry-run                           Print the changes. Do not apply them.
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
      --owners) service_principal_owners="$2"; shift 2 ;;
      --billing-agreement-type) billing_agreement_type="$2"; shift 2 ;;
      --billing-account-id) billing_account_id="$2"; shift 2 ;;
      --skip-billing-access) enable_top_level_billing_access=false; shift ;;
      --location) billing_exports_location="$2"; shift 2 ;;
      --resource-group) billing_exports_resource_group_name="$2"; shift 2 ;;
      --storage-account) billing_exports_storage_account_name="$2"; shift 2 ;;
      --existing-export) existing_export="$2"; shift 2 ;;
      --skip-billing-exports) enable_billing_exports=false; shift ;;
      --dry-run) dry_run=true; shift ;;
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

  if [ "$enable_billing_exports" = true ] && [ -z "$existing_export" ]; then
    [ -n "$billing_exports_location" ] || fail "--location is required to create the billing exports."
  fi

  if [ "$enable_top_level_billing_access" = true ] || { [ "$enable_billing_exports" = true ] && [ -z "$existing_export" ]; }; then
    [ -n "$billing_account_id" ] || fail "--billing-account-id is required."
    [[ "$billing_account_id" =~ $BILLING_ACCOUNT_ID_PATTERN ]] \
      || fail "--billing-account-id must be an EA enrollment number or an MCA billing account ID."
  fi

  [ -z "$existing_export" ] || parse_existing_export
  validate_storage_account_name

  local owner
  IFS=',' read -r -a owners_list <<<"$service_principal_owners"
  for owner in ${owners_list[@]+"${owners_list[@]}"}; do
    [[ "$owner" =~ $GUID_PATTERN ]] || fail "--owners must contain object ID GUIDs."
  done
}

ensure_service_principal() {
  local owner existing_owners
  log "Service principal for application ${infracost_client_id}"

  if [ -z "$service_principal_object_id" ]; then
    if [ "$dry_run" = true ]; then
      mutate az ad sp create --id "$infracost_client_id"
      service_principal_object_id="<service-principal-object-id>"
    else
      service_principal_object_id="$(az ad sp create --id "$infracost_client_id" --query id -o tsv --only-show-errors)"
    fi
  fi

  mutate az rest --method PATCH \
    --url "${GRAPH_URL}/servicePrincipals/${service_principal_object_id}" \
    --headers "Content-Type=application/json" \
    --body "{\"tags\":[\"WindowsAzureActiveDirectoryIntegratedApp\",\"InfracostModuleVersion:${SCRIPT_VERSION}\"]}"

  [ -n "$service_principal_owners" ] || return 0
  existing_owners="$(az rest --method GET \
    --url "${GRAPH_URL}/servicePrincipals/${service_principal_object_id}/owners?\$select=id" \
    --query "value[].id" -o tsv 2>/dev/null || true)"
  for owner in "${owners_list[@]}"; do
    grep -qx "$owner" <<<"$existing_owners" && continue
    mutate az rest --method POST \
      --url "${GRAPH_URL}/servicePrincipals/${service_principal_object_id}/owners/\$ref" \
      --headers "Content-Type=application/json" \
      --body "{\"@odata.id\":\"${GRAPH_URL}/directoryObjects/${owner}\"}"
  done
}

ensure_role_assignment() {
  local scope="$1" role="$2" description="$3" principal_id="$4" assignment_id
  assignment_id="$(az role assignment list --assignee "$principal_id" --scope "$scope" --role "$role" \
    --query "[0].id" -o tsv 2>/dev/null || true)"
  if [ -z "$assignment_id" ]; then
    if [ "$dry_run" = true ]; then
      mutate az role assignment create --assignee-object-id "$principal_id" \
        --assignee-principal-type ServicePrincipal --role "$role" --scope "$scope" --description "$description"
      assignment_id="<role-assignment-id>"
    else
      assignment_id="$(az role assignment create --assignee-object-id "$principal_id" \
        --assignee-principal-type ServicePrincipal --role "$role" --scope "$scope" --description "$description" \
        --query id -o tsv)"
    fi
  fi
  printf '%s\n' "$assignment_id"
}

ensure_management_group_roles() {
  local name scope role assignment_id
  role_assignment_ids_json=""
  IFS=',' read -r -a role_list <<<"$role_definition_names"
  while IFS='|' read -r name scope; do
    [ -n "$name" ] || continue
    for role in "${role_list[@]}"; do
      log "Role ${role} on management group ${name}"
      assignment_id="$(ensure_role_assignment "$scope" "$role" "Infracost read-only access" "$service_principal_object_id")"
      role_assignment_ids_json="${role_assignment_ids_json:+${role_assignment_ids_json},}$(json_string "${name}/${role}"):$(json_string "$assignment_id")"
    done
  done <<<"$management_group_scopes"
}

validate_billing_account() {
  local expected_agreement_type actual_agreement_type
  [ "$enable_top_level_billing_access" = true ] || return 0

  if [ "$billing_agreement_type" = EA ]; then
    expected_agreement_type="$EA_AGREEMENT_TYPE"
  else
    expected_agreement_type="$MCA_AGREEMENT_TYPE"
  fi

  actual_agreement_type="$(az rest --method GET \
    --url "/providers/Microsoft.Billing/billingAccounts/${billing_account_id}?api-version=${BILLING_API_VERSION}" \
    --query properties.agreementType -o tsv)" || fail "cannot read billing account ${billing_account_id}."
  [ "$actual_agreement_type" = "$expected_agreement_type" ] \
    || fail "--billing-agreement-type is ${billing_agreement_type}, but the billing account is ${actual_agreement_type}."
}

preflight() {
  local name scope resource_group_scope namespace
  [ "$skip_preflight" = false ] || { log "Skipping preflight"; return 0; }
  log "Preflight"

  require_service_principal_management "Service principal" "$service_principal_object_id"

  while IFS='|' read -r name scope; do
    [ -n "$name" ] || continue
    require_arm_actions "$scope" "Management group roles" \
      Microsoft.Authorization/roleAssignments/read Microsoft.Authorization/roleAssignments/write
  done <<<"$management_group_scopes"

  if [ "$enable_top_level_billing_access" = true ]; then
    require_billing_actions "Billing reader role" \
      Microsoft.Billing/billingAccounts/billingRoleAssignments/write
  fi

  [ "$enable_billing_exports" = true ] || { report_preflight; return 0; }

  if [ -n "$existing_export" ]; then
    if resource_exists "$existing_storage_account_id"; then
      require_arm_actions "$existing_storage_account_id" "Blob reader role on the existing export" \
        Microsoft.Authorization/roleAssignments/write
    else
      add_preflight_failure "Existing export: storage account ${existing_storage_account_id} not found"
    fi
    report_preflight
    return 0
  fi

  for namespace in $(unregistered_resource_providers); do
    require_arm_actions "/subscriptions/${subscription_id}" "Resource provider registration" "${namespace}/register/action"
  done

  if resource_group_exists; then
    resource_group_scope="/subscriptions/${subscription_id}/resourceGroups/${billing_exports_resource_group_name}"
  else
    resource_group_scope="/subscriptions/${subscription_id}"
  fi
  require_arm_actions "$resource_group_scope" "Billing exports storage" \
    Microsoft.Resources/subscriptions/resourceGroups/write \
    Microsoft.Storage/storageAccounts/write \
    Microsoft.Storage/storageAccounts/blobServices/containers/write \
    Microsoft.Storage/storageAccounts/managementPolicies/write \
    Microsoft.Authorization/roleAssignments/write

  if ! resource_exists "$(created_storage_account_id)" \
    && [ "$(az storage account check-name --name "$billing_exports_storage_account_name" \
      --query nameAvailable -o tsv 2>/dev/null || true)" = false ]; then
    add_preflight_failure "Storage account name ${billing_exports_storage_account_name} is in use. Pass --storage-account with a different name"
  fi

  require_billing_actions "FOCUS cost export" \
    Microsoft.CostManagement/exports/read Microsoft.CostManagement/exports/write

  report_preflight
}

ensure_billing_access() {
  local billing_account_resource_id="/providers/Microsoft.Billing/billingAccounts/${billing_account_id}"
  local role_definition_id properties

  billing_role_assignment_id=""
  [ "$enable_top_level_billing_access" = true ] || return 0

  role_definition_id="$(billing_role_definition_id)"
  log "Billing reader role on billing account ${billing_account_id}"

  properties="{\"principalId\":\"${service_principal_object_id}\",\"principalTenantId\":\"${tenant_id}\",\"roleDefinitionId\":\"${billing_account_resource_id}/billingRoleDefinitions/${role_definition_id}\"}"

  if [ "$billing_agreement_type" = EA ]; then
    ensure_enrollment_reader "$billing_account_resource_id" "$role_definition_id" "{\"properties\":${properties}}"
  else
    ensure_billing_account_reader "$billing_account_resource_id" "$role_definition_id" "$properties"
  fi
}

ensure_enrollment_reader() {
  local billing_account_resource_id="$1" role_definition_id="$2" body="$3" assignment_name url
  assignment_name="$(uuidv5_url "${billing_account_resource_id}/${service_principal_object_id}/${role_definition_id}")"
  url="${billing_account_resource_id}/billingRoleAssignments/${assignment_name}?api-version=${BILLING_API_VERSION}"
  if [ "$dry_run" = true ]; then
    mutate az rest --method PUT --url "$url" --body "$body"
    billing_role_assignment_id="${billing_account_resource_id}/billingRoleAssignments/${assignment_name}"
    return
  fi
  billing_role_assignment_id="$(az rest --method PUT --url "$url" --body "$body" --query id -o tsv)"
}

ensure_billing_account_reader() {
  local billing_account_resource_id="$1" role_definition_id="$2" properties="$3" assignment_resource_id
  assignment_resource_id="${billing_account_resource_id}/billingRoleAssignments/${role_definition_id}_${service_principal_object_id}"
  billing_role_assignment_id="$(az rest --method GET \
    --url "${assignment_resource_id}?api-version=${BILLING_API_VERSION}" \
    --query id -o tsv 2>/dev/null || true)"
  [ -z "$billing_role_assignment_id" ] || return 0

  if [ "$dry_run" = true ]; then
    mutate az rest --method POST \
      --url "${billing_account_resource_id}/createBillingRoleAssignment?api-version=${BILLING_API_VERSION}" \
      --body "$properties"
    billing_role_assignment_id="$assignment_resource_id"
    return
  fi
  billing_role_assignment_id="$(az rest --method POST \
    --url "${billing_account_resource_id}/createBillingRoleAssignment?api-version=${BILLING_API_VERSION}" \
    --body "$properties" --query id -o tsv)"
}

register_resource_providers() {
  local namespace
  for namespace in $(unregistered_resource_providers); do
    log "Resource provider ${namespace}"
    mutate az provider register --namespace "$namespace" --subscription "$subscription_id" --wait >/dev/null
  done
}

ensure_resource_group() {
  log "Resource group ${billing_exports_resource_group_name}"
  mutate az group create --name "$billing_exports_resource_group_name" --location "$billing_exports_location" \
    --tags "InfracostModuleVersion=${SCRIPT_VERSION}" --only-show-errors >/dev/null
}

ensure_storage_account() {
  log "Storage account ${billing_exports_storage_account_name}"
  storage_account_id="$(az storage account show --name "$billing_exports_storage_account_name" \
    --resource-group "$billing_exports_resource_group_name" --query id -o tsv 2>/dev/null || true)"
  if [ -z "$storage_account_id" ]; then
    mutate az storage account create --name "$billing_exports_storage_account_name" \
      --resource-group "$billing_exports_resource_group_name" --location "$billing_exports_location" \
      --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 --https-only true \
      --allow-blob-public-access false --allow-shared-key-access false \
      --default-to-oauth-authentication true --tags "InfracostModuleVersion=${SCRIPT_VERSION}" \
      --only-show-errors >/dev/null
  fi
  storage_account_id="$(created_storage_account_id)"
}

ensure_storage_container() {
  log "Storage container ${billing_exports_container_name}"
  [ "$(az storage container-rm exists --storage-account "$storage_account_id" \
    --name "$billing_exports_container_name" --query exists -o tsv 2>/dev/null || true)" = true ] && return 0
  mutate az storage container-rm create --storage-account "$storage_account_id" \
    --name "$billing_exports_container_name" --public-access off --only-show-errors >/dev/null
}

ensure_storage_management_policy() {
  log "Storage lifecycle policy"
  mutate az storage account management-policy create --account-name "$billing_exports_storage_account_name" \
    --resource-group "$billing_exports_resource_group_name" --only-show-errors \
    --policy "{\"rules\":[{\"name\":\"tierAndDeleteBillingExports\",\"enabled\":true,\"type\":\"Lifecycle\",\"definition\":{\"filters\":{\"blobTypes\":[\"blockBlob\"],\"prefixMatch\":[\"${billing_exports_container_name}/${billing_exports_root_path}\"]},\"actions\":{\"baseBlob\":{\"tierToCold\":{\"daysAfterModificationGreaterThan\":${cold_tier_after_days}},\"delete\":{\"daysAfterModificationGreaterThan\":${retention_days}}}}}}]}" \
    >/dev/null
}

ensure_focus_cost_export() {
  local url schedule_start body
  url="/providers/Microsoft.Billing/billingAccounts/${billing_account_id}/providers/Microsoft.CostManagement/exports/${billing_exports_export_name}?api-version=${COST_MANAGEMENT_API_VERSION}"
  log "FOCUS cost export ${billing_exports_export_name}"

  schedule_start="$(az rest --method GET --url "$url" \
    --query properties.schedule.recurrencePeriod.from -o tsv 2>/dev/null || true)"
  [ -n "$schedule_start" ] || schedule_start="$(tomorrow_utc)"

  body="{\"location\":\"${billing_exports_location}\",\"identity\":{\"type\":\"SystemAssigned\"},\"properties\":{\"format\":\"Parquet\",\"compressionMode\":\"snappy\",\"dataOverwriteBehavior\":\"OverwritePreviousReport\",\"partitionData\":true,\"definition\":{\"type\":\"FocusCost\",\"timeframe\":\"MonthToDate\",\"dataSet\":{\"granularity\":\"Daily\",\"configuration\":{\"dataVersion\":\"1.2-preview\"}}},\"deliveryInfo\":{\"destination\":{\"type\":\"AzureBlob\",\"resourceId\":\"${storage_account_id}\",\"container\":\"${billing_exports_container_name}\",\"rootFolderPath\":\"${billing_exports_root_path}\"}},\"schedule\":{\"status\":\"Active\",\"recurrence\":\"Daily\",\"recurrencePeriod\":{\"from\":\"${schedule_start}\",\"to\":\"2099-12-31T00:00:00Z\"}}}}"

  if [ "$dry_run" = true ]; then
    mutate az rest --method PUT --url "$url" --body "$body"
    export_id="/providers/Microsoft.Billing/billingAccounts/${billing_account_id}/providers/Microsoft.CostManagement/exports/${billing_exports_export_name}"
    export_principal_id="<export-identity-principal-id>"
    return
  fi
  read -r export_id export_principal_id < <(az rest --method PUT --url "$url" --body "$body" \
    --query "[id, identity.principalId]" -o tsv | tr '\n' ' ')
}

ensure_billing_exports() {
  local container_resource_id
  billing_exports_json="null"
  export_id=""
  [ "$enable_billing_exports" = true ] || return 0

  if [ -n "$existing_export" ]; then
    storage_account_id="$existing_storage_account_id"
    billing_exports_container_name="$existing_container"
    billing_exports_root_path="$existing_root_path"
  else
    register_resource_providers
    ensure_resource_group
    ensure_storage_account
    ensure_storage_container
    ensure_storage_management_policy
    ensure_focus_cost_export

    log "Role Storage Blob Data Contributor on storage account for the cost export"
    ensure_role_assignment "$storage_account_id" "Storage Blob Data Contributor" \
      "Infracost FOCUS cost export write access" "$export_principal_id" >/dev/null
  fi

  container_resource_id="${storage_account_id}/blobServices/default/containers/${billing_exports_container_name}"
  log "Role Storage Blob Data Reader on container ${billing_exports_container_name}"
  ensure_role_assignment "$container_resource_id" "Storage Blob Data Reader" \
    "Infracost read-only access to billing exports" "$service_principal_object_id" >/dev/null

  billing_exports_json="{\"storage_account_id\":$(json_string "$storage_account_id"),\"container\":$(json_string "$billing_exports_container_name"),\"root_path\":$(json_string "$billing_exports_root_path"),\"export_id\":$(json_string_or_null "$export_id")}"
}

print_outputs() {
  log "Values to provide to Infracost"
  cat <<EOF
{
  "tenant_id": $(json_string "$tenant_id"),
  "service_principal_object_id": $(json_string "$service_principal_object_id"),
  "management_group_ids": {${management_group_ids_json}},
  "role_assignment_ids": {${role_assignment_ids_json}},
  "billing_role_assignment_id": $(json_string_or_null "$billing_role_assignment_id"),
  "billing_exports": ${billing_exports_json}
}
EOF
}

main() {
  parse_args "$@"
  validate_args
  read_client_config
  read_management_groups
  read_service_principal
  resolve_storage_account_name
  validate_billing_account
  preflight
  ensure_service_principal
  ensure_management_group_roles
  ensure_billing_access
  ensure_billing_exports
  print_outputs
}

main "$@"
