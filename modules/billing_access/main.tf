terraform {
  required_version = ">= 1.16"

  required_providers {
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.0"
    }
  }
}

# Billing access assigns billing permissions to the Infracost application service principal.

locals {
  billing_api_version         = "2024-04-01"
  billing_account_resource_id = "/providers/Microsoft.Billing/billingAccounts/${var.billing_account_id}"

  # Only Enterprise Agreement and Microsoft Customer Agreement are currently supported
  billing_agreement_types = {
    EA  = local.ea_billing_agreement
    MCA = local.mca_billing_agreement
  }

  billing_agreement = local.billing_agreement_types[var.billing_agreement_type]

  billing_role_definition_resource_id = join("/", [
    local.billing_account_resource_id,
    "billingRoleDefinitions",
    local.billing_agreement.role_definition_id,
  ])

  billing_account_agreement_type = data.azapi_resource.billing_account.output.properties.agreementType

  billing_role_assignment_properties = {
    principalId       = var.service_principal_object_id
    principalTenantId = var.service_principal_tenant_id
    roleDefinitionId  = local.billing_role_definition_resource_id
  }
}

# https://learn.microsoft.com/en-us/rest/api/billing/billing-accounts/get?view=rest-billing-2024-04-01&tabs=HTTP
data "azapi_resource" "billing_account" {
  type                   = "Microsoft.Billing/billingAccounts@${local.billing_api_version}"
  resource_id            = local.billing_account_resource_id
  response_export_values = ["properties.agreementType"]
}

resource "terraform_data" "billing_preconditions" {
  input = local.billing_account_resource_id

  lifecycle {
    precondition {
      condition     = local.billing_account_agreement_type == local.billing_agreement.agreement_type
      error_message = "billing_agreement_type is ${var.billing_agreement_type}, but the billing account is ${local.billing_account_agreement_type}."
    }
  }
}
