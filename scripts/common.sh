#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154

SCRIPT_VERSION="0.5.0" # x-release-please-version

BILLING_API_VERSION="2024-04-01"
COST_MANAGEMENT_API_VERSION="2025-03-01"
GRAPH_URL="https://graph.microsoft.com/v1.0"
PERMISSIONS_API_VERSION="2022-04-01"

EA_AGREEMENT_TYPE="EnterpriseAgreement"
EA_ROLE_DEFINITION_ID="24f8edb6-1668-4659-b5e2-40bb5f3a7d7e"
MCA_AGREEMENT_TYPE="MicrosoftCustomerAgreement"
MCA_ROLE_DEFINITION_ID="50000000-aaaa-bbbb-cccc-100000000002"

UUID_URL_NAMESPACE="6ba7b8119dad11d180b400c04fd430c8"

REQUIRED_RESOURCE_PROVIDERS="Microsoft.Storage Microsoft.CostManagement Microsoft.CostManagementExports"

GLOBAL_ADMINISTRATOR_ROLE_TEMPLATE_ID="62e90394-69f5-4237-9190-012177145e10"
APPLICATION_ADMINISTRATOR_ROLE_TEMPLATE_ID="9b895d92-2cd3-44c7-9d02-a6ac2d5ea5c3"
CLOUD_APPLICATION_ADMINISTRATOR_ROLE_TEMPLATE_ID="158c047a-c907-4556-b7ef-446551a6b5f7"
APPLICATION_MANAGER_ROLE_TEMPLATE_IDS="${GLOBAL_ADMINISTRATOR_ROLE_TEMPLATE_ID},${APPLICATION_ADMINISTRATOR_ROLE_TEMPLATE_ID},${CLOUD_APPLICATION_ADMINISTRATOR_ROLE_TEMPLATE_ID}"
GRAPH_APPLICATION_READ_WRITE_ALL_ROLE_ID="1bfefb4e-e0b5-418b-a88f-73c46d2cc8e9"
GRAPH_APPLICATION_READ_WRITE_OWNED_BY_ROLE_ID="18a4783c-866b-4cc7-a460-3d5e5662c884"

GUID_PATTERN='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
BILLING_ACCOUNT_ID_PATTERN='^([0-9]+|[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}:[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}_[0-9]{4}-[0-9]{2}-[0-9]{2})$'
STORAGE_ACCOUNT_NAME_PATTERN='^[a-z0-9]{3,24}$'
STORAGE_ACCOUNT_ID_PATTERN='^/[sS]ubscriptions/[^/]+/[rR]esource[gG]roups/[^/]+/providers/[mM]icrosoft\.[sS]torage/[sS]torage[aA]ccounts/[^/]+$'

log() {
  printf '==> %s\n' "$*" >&2
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

mutate() {
  if [ "$dry_run" = true ]; then
    printf '[dry-run]' >&2
    printf ' %q' "$@" >&2
    printf '\n' >&2
    return 0
  fi
  "$@"
}

uuidv5_url() {
  local name="$1" hex escaped i digest
  hex="${UUID_URL_NAMESPACE}$(printf '%s' "$name" | od -An -tx1 -v | tr -d ' \n')"
  escaped=""
  i=0
  while [ "$i" -lt "${#hex}" ]; do
    escaped="${escaped}\\x${hex:$i:2}"
    i=$((i + 2))
  done
  digest="$(printf '%b' "$escaped" | shasum -a 1 | cut -c1-32)"
  printf '%s-%s-5%s-%x%s-%s\n' \
    "${digest:0:8}" "${digest:8:4}" "${digest:13:3}" \
    "$(((0x${digest:16:2} & 0x3f) | 0x80))" "${digest:18:2}" "${digest:20:12}"
}

tomorrow_utc() {
  date -u -v+1d '+%Y-%m-%dT00:00:00Z' 2>/dev/null || date -u -d tomorrow '+%Y-%m-%dT00:00:00Z'
}

json_string() {
  printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"
}

json_string_or_null() {
  if [ -n "$1" ]; then json_string "$1"; else printf 'null'; fi
}

read_client_config() {
  command -v az >/dev/null || fail "az CLI not found."
  tenant_id="$(az account show --query tenantId -o tsv)" \
    || fail "run 'az login${expected_tenant_id:+ --tenant ${expected_tenant_id}}' first."
  subscription_id="$(az account show --query id -o tsv)"

  if [ -n "$expected_tenant_id" ] && [ "$(lowercase "$tenant_id")" != "$(lowercase "$expected_tenant_id")" ]; then
    fail "the az CLI targets tenant ${tenant_id}, but --tenant-id is ${expected_tenant_id}. Run 'az login --tenant ${expected_tenant_id}'."
  fi
  if [ -n "$expected_subscription_id" ] && [ "$(lowercase "$subscription_id")" != "$(lowercase "$expected_subscription_id")" ]; then
    fail "the az CLI targets subscription ${subscription_id}, but --subscription is ${expected_subscription_id}. Run 'az account set --subscription ${expected_subscription_id}'."
  fi

  log "Tenant ${tenant_id}, subscription ${subscription_id}"
}

lowercase() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

validate_tenant_and_subscription_args() {
  [ -z "$expected_tenant_id" ] || [[ "$expected_tenant_id" =~ $GUID_PATTERN ]] || fail "--tenant-id must be a GUID."
  [ -z "$expected_subscription_id" ] || [[ "$expected_subscription_id" =~ $GUID_PATTERN ]] || fail "--subscription must be a GUID."
}

read_service_principal() {
  service_principal_object_id="$(az ad sp show --id "$infracost_client_id" --query id -o tsv 2>/dev/null || true)"
}

unregistered_resource_providers() {
  local namespace
  for namespace in $REQUIRED_RESOURCE_PROVIDERS; do
    [ "$(az provider show --namespace "$namespace" --subscription "$subscription_id" \
      --query registrationState -o tsv 2>/dev/null || true)" = Registered ] || printf '%s\n' "$namespace"
  done
}

resource_group_exists() {
  [ "$(az group exists --name "$billing_exports_resource_group_name" -o tsv 2>/dev/null || true)" = true ]
}

resource_exists() {
  az resource show --ids "$1" --query id -o tsv >/dev/null 2>&1
}

read_management_groups() {
  local name id
  [ -n "$management_group_names" ] || management_group_names="$tenant_id"
  management_group_ids_json=""
  management_group_scopes=""
  IFS=',' read -r -a management_group_list <<<"$management_group_names"
  for name in "${management_group_list[@]}"; do
    id="$(az account management-group show --name "$name" --query id -o tsv)" \
      || fail "management group ${name} not found."
    management_group_scopes="${management_group_scopes}${name}|${id}"$'\n'
    management_group_ids_json="${management_group_ids_json:+${management_group_ids_json},}$(json_string "$name"):$(json_string "$id")"
  done
}

resolve_storage_account_name() {
  [ -n "$billing_exports_storage_account_name" ] \
    || billing_exports_storage_account_name="infracost$(printf '%s' "$tenant_id" | shasum -a 1 | cut -c1-15)"
}

created_storage_account_id() {
  printf '/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Storage/storageAccounts/%s\n' \
    "$subscription_id" "$billing_exports_resource_group_name" "$billing_exports_storage_account_name"
}

validate_storage_account_name() {
  [ -z "$billing_exports_storage_account_name" ] \
    || [[ "$billing_exports_storage_account_name" =~ $STORAGE_ACCOUNT_NAME_PATTERN ]] \
    || fail "--storage-account must be 3 to 24 lowercase letters and numbers."
}

billing_role_definition_id() {
  if [ "$billing_agreement_type" = EA ]; then
    printf '%s\n' "$EA_ROLE_DEFINITION_ID"
  else
    printf '%s\n' "$MCA_ROLE_DEFINITION_ID"
  fi
}

parse_existing_export() {
  IFS=',' read -r existing_storage_account_id existing_container existing_root_path <<<"$existing_export"
  [[ "$existing_storage_account_id" =~ $STORAGE_ACCOUNT_ID_PATTERN ]] \
    || fail "--existing-export storage_account_id must be a storage account resource ID."
  [ -n "$existing_container" ] && [ -n "$existing_root_path" ] \
    || fail "--existing-export must be <storage_account_id>,<container>,<root_path>."
}

preflight_failures=""
preflight_unchecked=""

add_preflight_failure() {
  preflight_failures="${preflight_failures}  - $*"$'\n'
}

add_unchecked_permission() {
  preflight_unchecked="${preflight_unchecked}  - $*"$'\n'
}

lines_contain_any() {
  local lines="$1" candidates="$2" candidate
  IFS=',' read -r -a candidate_list <<<"$candidates"
  for candidate in "${candidate_list[@]}"; do
    grep -qix "$candidate" <<<"$lines" && return 0
  done
  return 1
}

action_matches_any() {
  local action pattern pattern_regex
  action="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  IFS=',' read -r -a pattern_list <<<"$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
  for pattern in ${pattern_list[@]+"${pattern_list[@]}"}; do
    pattern_regex="^$(sed 's/[.]/\\./g; s/[*]/.*/g' <<<"$pattern")$"
    [[ "$action" =~ $pattern_regex ]] && return 0
  done
  return 1
}

arm_action_allowed() {
  local action="$1" permission_entries="$2" allowed_actions denied_actions
  while IFS='|' read -r allowed_actions denied_actions; do
    action_matches_any "$action" "$allowed_actions" || continue
    action_matches_any "$action" "$denied_actions" && continue
    return 0
  done <<<"$permission_entries"
  return 1
}

require_arm_actions() {
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
    arm_action_allowed "$action" "$permission_entries" \
      || add_preflight_failure "${description}: ${action} on ${scope}"
  done
}

require_billing_actions() {
  local description="$1" action actions_json="" access_decisions access_decision
  shift
  for action in "$@"; do
    actions_json="${actions_json:+${actions_json},}$(json_string "$action")"
  done
  if ! access_decisions="$(az rest --method POST \
    --url "/providers/Microsoft.Billing/billingAccounts/${billing_account_id}/checkAccess?api-version=${BILLING_API_VERSION}" \
    --body "{\"actions\":[${actions_json}]}" \
    --query "[].join('|', [action, accessDecision])" -o tsv 2>/dev/null)"; then
    add_unchecked_permission "${description}: cannot check access on billing account ${billing_account_id}"
    return 0
  fi
  for action in "$@"; do
    access_decision="$(awk -F'|' -v action="$action" 'tolower($1) == tolower(action) { print $2 }' <<<"$access_decisions")"
    case "$access_decision" in
      Allowed) ;;
      NotAllowed) add_preflight_failure "${description}: ${action} on billing account ${billing_account_id}" ;;
      *) add_unchecked_permission "${description}: no access decision for ${action} on billing account ${billing_account_id}" ;;
    esac
  done
}

require_service_principal_management() {
  local description="$1" target_object_id="$2" caller_path caller_app_id granted_app_roles directory_roles caller_object_id owners
  if [ "$(az account show --query user.type -o tsv)" = servicePrincipal ]; then
    caller_app_id="$(az account show --query user.name -o tsv)"
    caller_path="${GRAPH_URL}/servicePrincipals(appId='${caller_app_id}')"
    if granted_app_roles="$(az rest --method GET --url "${caller_path}/appRoleAssignments?\$select=appRoleId" \
      --query "value[].appRoleId" -o tsv 2>/dev/null)"; then
      lines_contain_any "$granted_app_roles" "$GRAPH_APPLICATION_READ_WRITE_ALL_ROLE_ID" && return 0
      [ -z "$target_object_id" ] && lines_contain_any "$granted_app_roles" "$GRAPH_APPLICATION_READ_WRITE_OWNED_BY_ROLE_ID" && return 0
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
  lines_contain_any "$directory_roles" "$APPLICATION_MANAGER_ROLE_TEMPLATE_IDS" && return 0

  if [ -n "$target_object_id" ]; then
    caller_object_id="$(az rest --method GET --url "${caller_path}?\$select=id" --query id -o tsv 2>/dev/null || true)"
    owners="$(az rest --method GET --url "${GRAPH_URL}/servicePrincipals/${target_object_id}/owners?\$select=id" \
      --query "value[].id" -o tsv 2>/dev/null || true)"
    [ -n "$caller_object_id" ] && lines_contain_any "$owners" "$caller_object_id" && return 0
  fi

  add_preflight_failure "${description}: Application Administrator, Cloud Application Administrator or Global Administrator directory role, Application.ReadWrite.All, or ownership of the service principal"
}

report_preflight() {
  if [ -n "$preflight_unchecked" ]; then
    log "Preflight could not check these items. The run can still fail on them:"
    printf '%s' "$preflight_unchecked" >&2
  fi
  if [ -z "$preflight_failures" ]; then
    log "Preflight passed"
    return 0
  fi
  log "Preflight failed:"
  printf '%s' "$preflight_failures" >&2
  fail "fix the items above, or pass --skip-preflight."
}
