#!/usr/bin/env bash

# Version of the scripts. Set on each Azure item that the scripts create.
SCRIPT_VERSION="0.5.0" # x-release-please-version

# API versions and endpoints of the Azure REST APIs.
BILLING_API_VERSION="2024-04-01"
COST_MANAGEMENT_API_VERSION="2025-03-01"
PERMISSIONS_API_VERSION="2022-04-01"
GRAPH_URL="https://graph.microsoft.com/v1.0"

# Billing agreement types and their billing reader role definitions.
EA_AGREEMENT_TYPE="EnterpriseAgreement"
EA_ROLE_DEFINITION_ID="24f8edb6-1668-4659-b5e2-40bb5f3a7d7e"
MCA_AGREEMENT_TYPE="MicrosoftCustomerAgreement"
MCA_ROLE_DEFINITION_ID="50000000-aaaa-bbbb-cccc-100000000002"

# Directory roles and Microsoft Graph application permissions that allow you to manage the Infracost service principal.
GLOBAL_ADMINISTRATOR_ROLE_TEMPLATE_ID="62e90394-69f5-4237-9190-012177145e10"
APPLICATION_ADMINISTRATOR_ROLE_TEMPLATE_ID="9b895d92-2cd3-44c7-9d02-a6ac2d5ea5c3"
CLOUD_APPLICATION_ADMINISTRATOR_ROLE_TEMPLATE_ID="158c047a-c907-4556-b7ef-446551a6b5f7"
APPLICATION_MANAGER_ROLE_TEMPLATE_IDS="${GLOBAL_ADMINISTRATOR_ROLE_TEMPLATE_ID},${APPLICATION_ADMINISTRATOR_ROLE_TEMPLATE_ID},${CLOUD_APPLICATION_ADMINISTRATOR_ROLE_TEMPLATE_ID}"
GRAPH_APPLICATION_READ_WRITE_ALL_ROLE_ID="1bfefb4e-e0b5-418b-a88f-73c46d2cc8e9"
GRAPH_APPLICATION_READ_WRITE_OWNED_BY_ROLE_ID="18a4783c-866b-4cc7-a460-3d5e5662c884"

# UUID namespace for the billing role assignment name, and the resource providers that the billing exports need.
UUID_URL_NAMESPACE="6ba7b8119dad11d180b400c04fd430c8"
REQUIRED_RESOURCE_PROVIDERS="Microsoft.Storage Microsoft.CostManagement Microsoft.CostManagementExports"

# Names and settings of the items that the scripts create. Same values as the Terraform module.
DEFAULT_ROLES="Reader,Cost Management Reader,Monitoring Reader"
DEFAULT_RESOURCE_GROUP="infracost-billing-exports"
VERSION_TAG_NAME="InfracostModuleVersion"
STORAGE_ACCOUNT_NAME_PREFIX="infracost"
STORAGE_ACCOUNT_SKU="Standard_LRS"
CONTAINER_NAME="infracost-exports"
ROOT_PATH="focus-cost"
LIFECYCLE_RULE_NAME="tierAndDeleteBillingExports"
COLD_TIER_AFTER_DAYS=90
RETENTION_DAYS=365
EXPORT_NAME="InfracostDailyFocusExport"
EXPORT_DATA_VERSION="1.2-preview"
EXPORT_SCHEDULE_END="2099-12-31T00:00:00Z"

# Patterns to validate the options.
GUID_PATTERN='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
BILLING_ACCOUNT_ID_PATTERN='^([0-9]+|[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}:[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}_[0-9]{4}-[0-9]{2}-[0-9]{2})$'
STORAGE_ACCOUNT_NAME_PATTERN='^[a-z0-9]{3,24}$'
STORAGE_ACCOUNT_ID_PATTERN='^/[sS]ubscriptions/[^/]+/[rR]esource[gG]roups/[^/]+/providers/[mM]icrosoft\.[sS]torage/[sS]torage[aA]ccounts/[^/]+$'
SHELL_SAFE_ARGUMENT_PATTERN='^[A-Za-z0-9_./:=@,+-]+$'

# State that the scripts read from Azure or calculate during the run.
active_tenant_id=""
active_subscription_id=""
signed_in_principal_type=""
signed_in_principal_name=""
service_principal_object_id=""
management_group_scopes=""
management_group_ids_json=""
existing_storage_account_id=""
existing_container=""
existing_root_path=""
export_storage_account_id=""
export_container=""
export_root_path=""
preflight_passes=""
preflight_failures=""
preflight_unchecked=""

# Writes a progress line to stderr.
write_step() {
  printf '==> %s\n' "$*" >&2
}

# Writes an error to stderr and stops the script.
stop_with_error() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# Formats an az command as a shell line that you can copy and run.
format_az_command() {
  local argument formatted="az"
  for argument in "$@"; do
    argument="$(printf '%s' "$argument" | tr '\n' ' ' | tr -s ' ')"
    if [[ "$argument" =~ $SHELL_SAFE_ARGUMENT_PATTERN ]]; then
      formatted="${formatted} ${argument}"
    else
      formatted="${formatted} '$(printf '%s' "$argument" | sed "s/'/'\\\\''/g")'"
    fi
  done
  printf '%s\n' "$formatted"
}

# Runs an az command that changes Azure. With the dry run option, only prints it and returns the placeholder result.
invoke_az_mutation() {
  local dry_run_result=""
  if [ "$1" = --dry-run-result ]; then
    dry_run_result="$2"
    shift 2
  fi
  if [ "$dry_run" = true ]; then
    printf '[dry-run] %s\n' "$(format_az_command "$@")" >&2
    [ -z "$dry_run_result" ] || printf '%s\n' "$dry_run_result"
    return 0
  fi
  printf '[apply] %s\n' "$(format_az_command "$@")" >&2
  az "$@" --only-show-errors
}

# Reads the value of a command-line option. Stops if the value is missing.
read_option_value() {
  [ $# -ge 2 ] || stop_with_error "$1 needs a value."
  printf '%s' "$2"
}

# Splits comma-separated values into a list.
split_list_argument() {
  local item joined=""
  IFS=',' read -r -a item_list <<<"$1"
  for item in ${item_list[@]+"${item_list[@]}"}; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    [ -z "$item" ] || joined="${joined:+${joined},}${item}"
  done
  printf '%s' "$joined"
}

# Converts a value to lowercase.
lowercase() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# Converts a value to a JSON string.
json_string() {
  printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"
}

# Converts a value to a JSON string, or to null if it is empty.
json_string_or_null() {
  if [ -n "$1" ]; then json_string "$1"; else printf 'null'; fi
}

# Calculates the SHA-1 hash as hexadecimal.
get_sha1_hex() {
  if command -v sha1sum >/dev/null; then
    sha1sum | cut -c1-40
  else
    shasum -a 1 | cut -c1-40
  fi
}

# Calculates a name-based UUID (version 5). Gives the same billing role assignment name as the Terraform module.
get_uuid_v5_url() {
  local name="$1" hex escaped index digest
  hex="${UUID_URL_NAMESPACE}$(printf '%s' "$name" | od -An -tx1 -v | tr -d ' \n')"
  escaped=""
  index=0
  while [ "$index" -lt "${#hex}" ]; do
    escaped="${escaped}\\x${hex:$index:2}"
    index=$((index + 2))
  done
  digest="$(printf '%b' "$escaped" | get_sha1_hex | cut -c1-32)"
  printf '%s-%s-5%s-%x%s-%s\n' \
    "${digest:0:8}" "${digest:8:4}" "${digest:13:3}" \
    "$(((0x${digest:16:2} & 0x3f) | 0x80))" "${digest:18:2}" "${digest:20:12}"
}

# Gets the start of tomorrow in UTC, for the first run of the cost export.
get_tomorrow_utc() {
  date -u -v+1d '+%Y-%m-%dT00:00:00Z' 2>/dev/null \
    || date -u -d "@$(($(date -u +%s) + 86400))" '+%Y-%m-%dT00:00:00Z'
}

# Stops if a necessary local tool is missing.
assert_local_tools() {
  command -v az >/dev/null || stop_with_error "az CLI not found."
  command -v sha1sum >/dev/null || command -v shasum >/dev/null || stop_with_error "sha1sum or shasum not found."
  command -v od >/dev/null || stop_with_error "od not found."
  [ -n "$(get_tomorrow_utc 2>/dev/null)" ] || stop_with_error "date cannot compute tomorrow's date."
}

# Stops if the tenant or subscription value is not a GUID.
assert_tenant_and_subscription_arguments() {
  [ -z "$tenant_id" ] || [[ "$tenant_id" =~ $GUID_PATTERN ]] || stop_with_error "--tenant-id must be a GUID."
  [ -z "$subscription" ] || [[ "$subscription" =~ $GUID_PATTERN ]] || stop_with_error "--subscription must be a GUID."
}

# Stops if the billing agreement type or billing account ID is missing or not valid.
assert_billing_arguments() {
  if [ "$skip_billing_access" = false ]; then
    case "$billing_agreement_type" in
      EA | MCA) ;;
      *) stop_with_error "--billing-agreement-type must be EA or MCA, or pass --skip-billing-access." ;;
    esac
  fi
  if [ "$skip_billing_access" = false ] || { [ "$skip_billing_exports" = false ] && [ -z "$existing_export" ]; }; then
    [ -n "$billing_account_id" ] || stop_with_error "--billing-account-id is required."
    [[ "$billing_account_id" =~ $BILLING_ACCOUNT_ID_PATTERN ]] \
      || stop_with_error "--billing-account-id must be an EA enrollment number or an MCA billing account ID."
  fi
}

# Stops if the storage account name is not valid.
assert_storage_account_name() {
  [ -z "$storage_account" ] \
    || [[ "$storage_account" =~ $STORAGE_ACCOUNT_NAME_PATTERN ]] \
    || stop_with_error "--storage-account must be 3 to 24 lowercase letters and numbers."
}

# Reads the storage account, container and path of the existing export, and stops if a value is not valid.
read_existing_export() {
  IFS=',' read -r existing_storage_account_id existing_container existing_root_path <<<"$existing_export"
  [[ "$existing_storage_account_id" =~ $STORAGE_ACCOUNT_ID_PATTERN ]] \
    || stop_with_error "--existing-export storage_account_id must be a storage account resource ID."
  [ -n "$existing_container" ] && [ -n "$existing_root_path" ] \
    || stop_with_error "--existing-export must be <storage_account_id>,<container>,<root_path>."
}

# Reads the tenant, subscription and principal of the az CLI, and stops if they are not the expected ones.
read_client_config() {
  local account
  account="$(az account show --query "join('|', [tenantId, id, user.type, user.name])" -o tsv)" \
    || stop_with_error "run 'az login${tenant_id:+ --tenant ${tenant_id}}' first."
  IFS='|' read -r active_tenant_id active_subscription_id signed_in_principal_type signed_in_principal_name <<<"$account"

  if [ -n "$tenant_id" ] && [ "$(lowercase "$active_tenant_id")" != "$(lowercase "$tenant_id")" ]; then
    stop_with_error "the az CLI targets tenant ${active_tenant_id}, but --tenant-id is ${tenant_id}. Run 'az login --tenant ${tenant_id}'."
  fi
  if [ -n "$subscription" ] && [ "$(lowercase "$active_subscription_id")" != "$(lowercase "$subscription")" ]; then
    stop_with_error "the az CLI targets subscription ${active_subscription_id}, but --subscription is ${subscription}. Run 'az account set --subscription ${subscription}'."
  fi

  write_step "Tenant ${active_tenant_id}, subscription ${active_subscription_id}"
}

# Gets the resource ID of each management group. Uses the tenant root management group if no group is given.
read_management_groups() {
  local name id management_group_names="${management_groups:-$active_tenant_id}"
  IFS=',' read -r -a management_group_list <<<"$management_group_names"
  for name in "${management_group_list[@]}"; do
    id="$(az account management-group show --name "$name" --query id -o tsv)" \
      || stop_with_error "management group ${name} not found."
    management_group_scopes="${management_group_scopes}${name}|${id}"$'\n'
    management_group_ids_json="${management_group_ids_json:+${management_group_ids_json},}$(json_string "$name"):$(json_string "$id")"
  done
}

# Gets the object ID of the Infracost service principal, if it exists in the tenant.
read_service_principal() {
  service_principal_object_id="$(az ad sp show --id "$client_id" --query id -o tsv 2>/dev/null || true)"
}

# Calculates the storage account name from the tenant ID, if no name is given.
resolve_storage_account_name() {
  [ -n "$storage_account" ] \
    || storage_account="${STORAGE_ACCOUNT_NAME_PREFIX}$(printf '%s' "$active_tenant_id" | get_sha1_hex | cut -c1-15)"
}

# Sets the storage account, container and path where the cost export writes.
resolve_export_destination() {
  if [ -n "$existing_export" ]; then
    export_storage_account_id="$existing_storage_account_id"
    export_container="$existing_container"
    export_root_path="$existing_root_path"
  else
    export_storage_account_id="/subscriptions/${active_subscription_id}/resourceGroups/${resource_group}/providers/Microsoft.Storage/storageAccounts/${storage_account}"
    export_container="$CONTAINER_NAME"
    export_root_path="$ROOT_PATH"
  fi
}

# Gets the billing reader role for the billing agreement type.
get_billing_role_definition_id() {
  if [ "$billing_agreement_type" = EA ]; then
    printf '%s\n' "$EA_ROLE_DEFINITION_ID"
  else
    printf '%s\n' "$MCA_ROLE_DEFINITION_ID"
  fi
}

# Lists the necessary resource providers that are not registered on the subscription.
get_unregistered_resource_providers() {
  local namespace registration_state
  for namespace in $REQUIRED_RESOURCE_PROVIDERS; do
    registration_state="$(az provider show --namespace "$namespace" --subscription "$active_subscription_id" \
      --query registrationState -o tsv 2>/dev/null || true)"
    [ "$registration_state" = Registered ] || printf '%s\n' "$namespace"
  done
}

# Checks if the resource group exists.
test_resource_group_exists() {
  [ "$(az group exists --name "$resource_group" -o tsv 2>/dev/null || true)" = true ]
}

# Checks if an Azure resource exists.
test_resource_exists() {
  az resource show --ids "$1" --query id -o tsv >/dev/null 2>&1
}

# Gets the version tag of the export storage account. Empty if the account does not exist or the setup script did not create it.
get_storage_account_version_tag() {
  az storage account show --ids "$export_storage_account_id" \
    --query "tags.${VERSION_TAG_NAME}" -o tsv 2>/dev/null || true
}

# Records a permission that the preflight confirmed.
add_preflight_pass() {
  preflight_passes="${preflight_passes}  - $*"$'\n'
}

# Records a permission that is missing.
add_preflight_failure() {
  preflight_failures="${preflight_failures}  - $*"$'\n'
}

# Records a permission that the preflight cannot check.
add_unchecked_permission() {
  preflight_unchecked="${preflight_unchecked}  - $*"$'\n'
}

# Checks if a list contains one of the values, without case.
test_lines_contain_any() {
  local lines="$1" candidates="$2" candidate
  IFS=',' read -r -a candidate_list <<<"$candidates"
  for candidate in "${candidate_list[@]}"; do
    grep -qix "$candidate" <<<"$lines" && return 0
  done
  return 1
}

# Checks if an action matches one of the action patterns, with * as a wildcard.
test_action_matches_any() {
  local action pattern pattern_regex
  action="$(lowercase "$1")"
  IFS=',' read -r -a pattern_list <<<"$(lowercase "$2")"
  for pattern in ${pattern_list[@]+"${pattern_list[@]}"}; do
    pattern_regex="^$(sed 's/[.]/\\./g; s/[*]/.*/g' <<<"$pattern")$"
    [[ "$action" =~ $pattern_regex ]] && return 0
  done
  return 1
}

# Checks if the permissions allow an action and do not deny it.
test_arm_action_allowed() {
  local action="$1" permission_entries="$2" allowed_actions denied_actions
  while IFS='|' read -r allowed_actions denied_actions; do
    test_action_matches_any "$action" "$allowed_actions" || continue
    test_action_matches_any "$action" "$denied_actions" && continue
    return 0
  done <<<"$permission_entries"
  return 1
}

# Checks that the signed-in principal can do each Azure action on a scope.
assert_arm_actions() {
  local scope="$1" description="$2" permission_entries action
  shift 2
  if ! permission_entries="$(az rest --method GET \
    --url "${scope}/providers/Microsoft.Authorization/permissions?api-version=${PERMISSIONS_API_VERSION}" \
    --query "value[].join('|', [join(',', actions || \`[]\`), join(',', notActions || \`[]\`)])" \
    -o tsv 2>/dev/null)"; then
    add_unchecked_permission "${description}: cannot read the permissions on ${scope}"
    return 0
  fi
  for action in "$@"; do
    if test_arm_action_allowed "$action" "$permission_entries"; then
      add_preflight_pass "${description}: ${action} on ${scope}"
    else
      add_preflight_failure "${description}: ${action} on ${scope}"
    fi
  done
}

# Checks that the signed-in principal can do each billing action on the billing account.
assert_billing_actions() {
  local description="$1" action actions_json="" access_decisions access_decision
  shift
  for action in "$@"; do
    actions_json="${actions_json:+${actions_json}, }$(json_string "$action")"
  done
  if ! access_decisions="$(az rest --method POST \
    --url "/providers/Microsoft.Billing/billingAccounts/${billing_account_id}/checkAccess?api-version=${BILLING_API_VERSION}" \
    --body "{ \"actions\": [${actions_json}] }" \
    --query "[].join('|', [action, accessDecision])" -o tsv 2>/dev/null)"; then
    add_unchecked_permission "${description}: cannot check access on billing account ${billing_account_id}"
    return 0
  fi
  for action in "$@"; do
    access_decision="$(awk -F'|' -v action="$action" 'tolower($1) == tolower(action) { print $2 }' <<<"$access_decisions")"
    case "$access_decision" in
      Allowed) add_preflight_pass "${description}: ${action} on billing account ${billing_account_id}" ;;
      NotAllowed) add_preflight_failure "${description}: ${action} on billing account ${billing_account_id}" ;;
      *) add_unchecked_permission "${description}: no access decision for ${action} on billing account ${billing_account_id}" ;;
    esac
  done
}

# Checks that the signed-in principal can create or change the Infracost service principal.
assert_service_principal_management() {
  local description="$1" target_object_id="$2" caller_path granted_app_roles directory_roles caller_object_id owner_ids
  if [ "$signed_in_principal_type" = servicePrincipal ]; then
    caller_path="${GRAPH_URL}/servicePrincipals(appId='${signed_in_principal_name}')"
    if granted_app_roles="$(az rest --method GET --url "${caller_path}/appRoleAssignments?\$select=appRoleId" \
      --query "value[].appRoleId" -o tsv 2>/dev/null)"; then
      if test_lines_contain_any "$granted_app_roles" "$GRAPH_APPLICATION_READ_WRITE_ALL_ROLE_ID"; then
        add_preflight_pass "${description}: Application.ReadWrite.All"
        return 0
      fi
      if [ -z "$target_object_id" ] && test_lines_contain_any "$granted_app_roles" "$GRAPH_APPLICATION_READ_WRITE_OWNED_BY_ROLE_ID"; then
        add_preflight_pass "${description}: Application.ReadWrite.OwnedBy"
        return 0
      fi
    fi
  else
    caller_path="${GRAPH_URL}/me"
  fi

  if ! directory_roles="$(az rest --method GET \
    --url "${caller_path}/transitiveMemberOf/microsoft.graph.directoryRole?\$select=roleTemplateId" \
    --query "value[].roleTemplateId" -o tsv 2>/dev/null)"; then
    add_unchecked_permission "${description}: cannot read the directory roles of the signed-in principal"
    return 0
  fi
  if test_lines_contain_any "$directory_roles" "$APPLICATION_MANAGER_ROLE_TEMPLATE_IDS"; then
    add_preflight_pass "${description}: Application Administrator, Cloud Application Administrator or Global Administrator directory role"
    return 0
  fi

  if [ -n "$target_object_id" ]; then
    caller_object_id="$(az rest --method GET --url "${caller_path}?\$select=id" --query id -o tsv 2>/dev/null || true)"
    owner_ids="$(az rest --method GET --url "${GRAPH_URL}/servicePrincipals/${target_object_id}/owners?\$select=id" \
      --query "value[].id" -o tsv 2>/dev/null || true)"
    if [ -n "$caller_object_id" ] && test_lines_contain_any "$owner_ids" "$caller_object_id"; then
      add_preflight_pass "${description}: owner of the service principal"
      return 0
    fi
  fi

  add_preflight_failure "${description}: Application Administrator, Cloud Application Administrator or Global Administrator directory role, Application.ReadWrite.All, or ownership of the service principal"
}

# Checks the role assignment permissions on each management group.
assert_management_group_role_permissions() {
  local name scope
  while IFS='|' read -r name scope; do
    [ -n "$name" ] || continue
    assert_arm_actions "$scope" "Management group roles" "$@"
  done <<<"$management_group_scopes"
}

# Writes the preflight result. Stops if a permission is missing.
write_preflight_report() {
  if [ -n "$preflight_passes" ]; then
    write_step "Preflight checks that passed:"
    printf '%s' "$preflight_passes" >&2
  fi
  if [ -n "$preflight_unchecked" ]; then
    write_step "Preflight could not check these items. The run can still fail on them:"
    printf '%s' "$preflight_unchecked" >&2
  fi
  if [ -z "$preflight_failures" ]; then
    write_step "Preflight passed"
    return 0
  fi
  write_step "Preflight failed:"
  printf '%s' "$preflight_failures" >&2
  stop_with_error "fix the items above, or pass --skip-preflight."
}
