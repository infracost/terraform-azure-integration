terraform {
  required_version = ">= 1.16"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.0"
    }
  }
}

locals {
  create_billing_exports = var.provision_billing_exports

  storage_account_id = local.create_billing_exports ? azurerm_storage_account.billing_exports[0].id : var.existing_billing_exports.storage_account_id
  container_name     = local.create_billing_exports ? azurerm_storage_container.billing_exports[0].name : var.existing_billing_exports.container
  root_path          = local.create_billing_exports ? var.root_path : var.existing_billing_exports.root_path

  container_resource_id = join("/", [
    local.storage_account_id,
    "blobServices/default/containers",
    local.container_name,
  ])
}

resource "azurerm_role_assignment" "blob_reader" {
  scope                = local.container_resource_id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = var.service_principal_object_id
  principal_type       = "ServicePrincipal"
  description          = "Infracost read-only access to billing exports"
}
