output "tenant_id" {
  description = "The Azure AD tenant ID where the module was provisioned. Provide this to Infracost."
  value       = data.azuread_client_config.current.tenant_id
}

output "service_principal_object_id" {
  description = "Object ID of the Infracost service principal in this tenant."
  value       = azuread_service_principal.infracost.object_id
}

output "management_group_ids" {
  description = "Resource IDs of the management groups where the roles are assigned, keyed by management group name."
  value       = { for name, management_group in data.azurerm_management_group.scope : name => management_group.id }
}

output "role_assignment_ids" {
  description = "Role assignment IDs, keyed by \"<management group name>/<role name>\"."
  value       = { for name, assignment in azurerm_role_assignment.infracost : name => assignment.id }
}

output "billing_role_assignment_id" {
  description = "ID of the billing role assignment on the billing account: EnrollmentReader for EA, Billing account reader for MCA."
  value       = var.billing_agreement_type == "EA" ? azapi_resource.enrollment_reader[0].id : local.billing_account_reader_assignment_resource_id
}
