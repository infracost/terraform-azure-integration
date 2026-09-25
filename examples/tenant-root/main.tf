terraform {
  required_version = ">= 1.16"
}

provider "azuread" {}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

variable "subscription_id" {
  description = "Any subscription in the tenant. The azurerm provider requires one, but role assignments are made at the management group scope."
  type        = string
}

variable "infracost_client_id" {
  description = "Client ID of the Infracost multi-tenant application."
  type        = string
}

module "infracost" {
  source = "../.."

  infracost_client_id = var.infracost_client_id
}

output "tenant_id" {
  value = module.infracost.tenant_id
}

output "service_principal_object_id" {
  value = module.infracost.service_principal_object_id
}
