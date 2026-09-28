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
  description          = "Infracost read-only access (module ${local.module_version})"
}
