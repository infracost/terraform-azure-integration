locals {
  ea_billing_agreement = {
    agreement_type     = "EnterpriseAgreement"
    role_name          = "EnrollmentReader"
    role_definition_id = "24f8edb6-1668-4659-b5e2-40bb5f3a7d7e"
    caller_role_name   = "Enterprise Administrator"
    caller_role_id     = "9f1983cb-2574-400c-87e9-34cf8e2280db"
  }

  enrollment_reader_assignment_name = uuidv5("url", join("/", [
    local.billing_account_resource_id,
    var.service_principal_object_id,
    local.billing_agreement.role_definition_id,
  ]))
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
