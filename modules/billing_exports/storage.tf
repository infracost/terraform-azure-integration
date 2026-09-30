locals {
  required_resource_providers = toset([
    "Microsoft.Storage",
    "Microsoft.CostManagement",
    "Microsoft.CostManagementExports",
  ])
}

resource "azapi_resource_action" "resource_provider_registration" {
  for_each = local.create_billing_exports ? local.required_resource_providers : toset([])

  type        = "Microsoft.Resources/providers@2021-04-01"
  resource_id = "/subscriptions/${var.subscription_id}/providers/${each.value}"
  action      = "register"
  method      = "POST"
}

resource "azurerm_resource_group" "billing_exports" {
  count = local.create_billing_exports ? 1 : 0

  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_storage_account" "billing_exports" {
  count = local.create_billing_exports ? 1 : 0

  name                            = var.storage_account_name
  resource_group_name             = azurerm_resource_group.billing_exports[0].name
  location                        = azurerm_resource_group.billing_exports[0].location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  tags                            = var.tags

  depends_on = [azapi_resource_action.resource_provider_registration]
}

resource "azurerm_storage_container" "billing_exports" {
  count = local.create_billing_exports ? 1 : 0

  name                  = var.container_name
  storage_account_id    = azurerm_storage_account.billing_exports[0].id
  container_access_type = "private"
}

resource "azurerm_storage_management_policy" "billing_exports" {
  count = local.create_billing_exports ? 1 : 0

  storage_account_id = azurerm_storage_account.billing_exports[0].id

  rule {
    name    = "tierAndDeleteBillingExports"
    enabled = true

    filters {
      blob_types   = ["blockBlob"]
      prefix_match = ["${azurerm_storage_container.billing_exports[0].name}/${var.root_path}"]
    }

    actions {
      base_blob {
        tier_to_cool_after_days_since_modification_greater_than    = var.cool_tier_after_days
        tier_to_archive_after_days_since_modification_greater_than = var.archive_tier_after_days
        delete_after_days_since_modification_greater_than          = var.retention_days
      }
    }
  }
}
