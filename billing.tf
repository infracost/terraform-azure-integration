# Billing assigns billing permissions to the Infracost application service principal.

locals {
  billing_api_version         = "2024-04-01"
  billing_account_resource_id = "/providers/Microsoft.Billing/billingAccounts/${var.billing_account_id}"

  # Only Enterprise Agreement and Microsoft Customer Agreement are currently supported
  billing_agreement_types = {
    EA = {
      agreement_type     = "EnterpriseAgreement"
      role_name          = "EnrollmentReader"
      role_definition_id = "24f8edb6-1668-4659-b5e2-40bb5f3a7d7e"
      caller_role_name   = "Enterprise Administrator"
      caller_role_id     = "9f1983cb-2574-400c-87e9-34cf8e2280db"
    }
    MCA = {
      agreement_type     = "MicrosoftCustomerAgreement"
      role_name          = "Billing account reader"
      role_definition_id = "50000000-aaaa-bbbb-cccc-100000000002"
      caller_role_name   = "Billing account owner"
      caller_role_id     = "50000000-aaaa-bbbb-cccc-100000000000"
    }
  }

  billing_agreement = local.billing_agreement_types[var.billing_agreement_type]

  billing_role_definition_resource_id = "${local.billing_account_resource_id}/billingRoleDefinitions/${local.billing_agreement.role_definition_id}"
  caller_billing_actions              = flatten([for permission in data.azapi_resource_action.caller_billing_permissions.output.value : permission.actions])
  caller_required_billing_actions     = flatten([for permission in data.azapi_resource.caller_required_billing_role.output.properties.permissions : permission.actions])
  caller_missing_billing_actions      = setsubtract(local.caller_required_billing_actions, local.caller_billing_actions)

  billing_role_assignment_properties = {
    principalId       = azuread_service_principal.infracost.object_id
    principalTenantId = data.azuread_client_config.current.tenant_id
    roleDefinitionId  = local.billing_role_definition_resource_id
  }

  enrollment_reader_assignment_name             = uuidv5("url", "${local.billing_account_resource_id}/${azuread_service_principal.infracost.object_id}/${local.billing_agreement.role_definition_id}")
  billing_account_reader_assignment_resource_id = "${local.billing_account_resource_id}/billingRoleAssignments/${local.billing_agreement.role_definition_id}_${azuread_service_principal.infracost.object_id}"
}

# https://learn.microsoft.com/en-us/rest/api/billing/billing-accounts/get?view=rest-billing-2024-04-01&tabs=HTTP
data "azapi_resource" "billing_account" {
  type                   = "Microsoft.Billing/billingAccounts@${local.billing_api_version}"
  resource_id            = local.billing_account_resource_id
  response_export_values = ["properties.agreementType"]
}

# https://learn.microsoft.com/en-us/rest/api/billing/billing-role-definition/get-by-billing-account?view=rest-billing-2024-04-01&tabs=HTTP
data "azapi_resource" "caller_required_billing_role" {
  type                   = "Microsoft.Billing/billingAccounts/billingRoleDefinitions@${local.billing_api_version}"
  resource_id            = "${local.billing_account_resource_id}/billingRoleDefinitions/${local.billing_agreement.caller_role_id}"
  response_export_values = ["properties.permissions"]
}

# https://learn.microsoft.com/en-us/rest/api/billing/billing-permissions/list-by-billing-account?view=rest-billing-2024-04-01&tabs=HTTP
data "azapi_resource_action" "caller_billing_permissions" {
  type                   = "Microsoft.Billing/billingAccounts@${local.billing_api_version}"
  resource_id            = local.billing_account_resource_id
  action                 = "billingPermissions"
  method                 = "GET"
  response_export_values = ["value"]
}

resource "terraform_data" "billing_preconditions" {
  input = local.billing_account_resource_id

  lifecycle {
    precondition {
      condition     = data.azapi_resource.billing_account.output.properties.agreementType == local.billing_agreement.agreement_type
      error_message = "Billing account ${var.billing_account_id} has agreement type ${data.azapi_resource.billing_account.output.properties.agreementType}, but billing_agreement_type is ${var.billing_agreement_type} (${local.billing_agreement.agreement_type})."
    }

    precondition {
      condition     = length(local.caller_missing_billing_actions) == 0
      error_message = "The principal running Terraform cannot assign billing roles on billing account ${var.billing_account_id}. It must have the ${local.billing_agreement.caller_role_name} role. Missing billing actions: ${join(", ", sort(local.caller_missing_billing_actions))}."
    }
  }
}

# https://learn.microsoft.com/en-us/rest/api/billing/billing-role-assignments/create-or-update-by-billing-account?view=rest-billing-2024-04-01&tabs=HTTP
resource "azapi_resource" "enrollment_reader" {
  count = var.billing_agreement_type == "EA" ? 1 : 0

  type      = "Microsoft.Billing/billingAccounts/billingRoleAssignments@${local.billing_api_version}"
  name      = local.enrollment_reader_assignment_name
  parent_id = local.billing_account_resource_id

  body = {
    properties = local.billing_role_assignment_properties
  }

  depends_on = [terraform_data.billing_preconditions]
}

# https://learn.microsoft.com/en-us/rest/api/billing/billing-role-assignments/create-by-billing-account?view=rest-billing-2024-04-01&tabs=HTTP
resource "azapi_resource_action" "billing_account_reader" {
  count = var.billing_agreement_type == "MCA" ? 1 : 0

  type        = "Microsoft.Billing/billingAccounts@${local.billing_api_version}"
  resource_id = local.billing_account_resource_id
  action      = "createBillingRoleAssignment"
  method      = "POST"
  body        = local.billing_role_assignment_properties

  response_export_values = ["id"]

  depends_on = [terraform_data.billing_preconditions]
}

# https://learn.microsoft.com/en-us/rest/api/billing/billing-role-assignments/delete-by-billing-account?view=rest-billing-2024-04-01&tabs=HTTP
resource "azapi_resource_action" "billing_account_reader_removal" {
  count = var.billing_agreement_type == "MCA" ? 1 : 0

  type        = "Microsoft.Billing/billingAccounts/billingRoleAssignments@${local.billing_api_version}"
  resource_id = local.billing_account_reader_assignment_resource_id
  method      = "DELETE"
  when        = "destroy"

  depends_on = [azapi_resource_action.billing_account_reader]
}
