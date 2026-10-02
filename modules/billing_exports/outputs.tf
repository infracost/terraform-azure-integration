output "storage_account_id" {
  description = "Resource ID of the storage account that contains the billing exports."
  value       = local.storage_account_id
}

output "container_name" {
  description = "Name of the blob container that contains the billing exports."
  value       = local.container_name
}

output "root_path" {
  description = "Folder path in the container where the billing exports are written."
  value       = local.root_path
}

output "export_id" {
  description = "Resource ID of the FOCUS cost export. Null if provision_billing_exports is false."
  value       = one(azapi_resource.focus_cost_export[*].id)
}

output "blob_reader_role_assignment_id" {
  description = "ID of the Storage Blob Data Reader role assignment on the container."
  value       = azurerm_role_assignment.blob_reader.id
}
