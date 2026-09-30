terraform {
  required_version = ">= 1.16"

  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
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

data "azuread_client_config" "current" {}

data "azurerm_client_config" "current" {}

locals {
  common_tags = {
    InfracostModuleVersion = local.module_version
  }

  management_group_names = length(var.management_group_names) > 0 ? toset(var.management_group_names) : toset([data.azuread_client_config.current.tenant_id])

  role_assignments = {
    for pair in setproduct(local.management_group_names, var.role_definition_names) :
    "${pair[0]}/${pair[1]}" => {
      management_group_name = pair[0]
      role_definition_name  = pair[1]
    }
  }
}

data "azurerm_management_group" "scope" {
  for_each = local.management_group_names

  name = each.value

  lifecycle {
    precondition {
      condition     = data.azurerm_client_config.current.tenant_id == data.azuread_client_config.current.tenant_id
      error_message = "The azuread and azurerm providers must target the same tenant."
    }
  }
}

resource "azuread_service_principal" "infracost" {
  client_id    = var.infracost_client_id
  use_existing = true
  owners       = var.service_principal_owners
  tags = concat(
    ["WindowsAzureActiveDirectoryIntegratedApp"],
    [for key, value in local.common_tags : "${key}:${value}"],
  )
}

resource "azurerm_role_assignment" "infracost" {
  for_each = local.role_assignments

  scope                = data.azurerm_management_group.scope[each.value.management_group_name].id
  role_definition_name = each.value.role_definition_name
  principal_id         = azuread_service_principal.infracost.object_id
  principal_type       = "ServicePrincipal"
  description          = "Infracost read-only access"
}

module "billing_access" {
  count  = var.enable_top_level_billing_access ? 1 : 0
  source = "./modules/billing_access"

  billing_agreement_type      = var.billing_agreement_type
  billing_account_id          = var.billing_account_id
  service_principal_object_id = azuread_service_principal.infracost.object_id
  service_principal_tenant_id = data.azuread_client_config.current.tenant_id
}

moved {
  from = module.billing
  to   = module.billing_access
}

module "billing_exports" {
  count  = var.enable_billing_exports ? 1 : 0
  source = "./modules/billing_exports"

  service_principal_object_id = azuread_service_principal.infracost.object_id
  provision_billing_exports   = var.provision_billing_exports
  existing_billing_exports    = var.existing_billing_exports
  billing_account_id          = var.billing_account_id
  subscription_id             = data.azurerm_client_config.current.subscription_id
  location                    = var.billing_exports_location
  resource_group_name         = var.billing_exports_resource_group_name
  storage_account_name        = coalesce(var.billing_exports_storage_account_name, "infracost${substr(sha1(data.azuread_client_config.current.tenant_id), 0, 15)}")
  tags                        = local.common_tags
}
