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
  description = "ID of the billing role assignment on the billing account: EnrollmentReader for EA, Billing account reader for MCA. Null if enable_top_level_billing_access is false."
  value       = one(module.billing_access[*].role_assignment_id)
}

output "billing_exports" {
  description = "Location of the billing exports that Infracost reads. Provide this to Infracost. Null if enable_billing_exports is false."
  value = var.enable_billing_exports ? {
    storage_account_id = module.billing_exports[0].storage_account_id
    container          = module.billing_exports[0].container_name
    root_path          = module.billing_exports[0].root_path
    export_id          = module.billing_exports[0].export_id
  } : null
}
