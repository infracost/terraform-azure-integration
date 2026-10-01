locals {
  mca_billing_agreement = {
    agreement_type     = "MicrosoftCustomerAgreement"
    role_name          = "Billing account reader"
    role_definition_id = "50000000-aaaa-bbbb-cccc-100000000002"
  }

  billing_account_reader_assignment_name = join("_", [
    local.billing_agreement.role_definition_id,
    var.service_principal_object_id,
  ])

  billing_account_reader_assignment_resource_id = join("/", [
    local.billing_account_resource_id,
    "billingRoleAssignments",
    local.billing_account_reader_assignment_name,
  ])
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
