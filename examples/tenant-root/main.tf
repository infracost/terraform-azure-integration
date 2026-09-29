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

provider "azuread" {}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

provider "azapi" {}

variable "subscription_id" {
  description = "Any subscription in the tenant. The azurerm provider requires one, but role assignments are made at the management group scope."
  type        = string
}

variable "infracost_client_id" {
  description = "Client ID of the Infracost multi-tenant application."
  type        = string
}

variable "billing_agreement_type" {
  description = "Billing agreement of the billing account: EA or MCA."
  type        = string
}

variable "billing_account_id" {
  description = "ID of the EA enrollment or MCA billing account."
  type        = string
}

module "infracost" {
  source = "../.."

  infracost_client_id    = var.infracost_client_id
  billing_agreement_type = var.billing_agreement_type
  billing_account_id     = var.billing_account_id
}

output "tenant_id" {
  value = module.infracost.tenant_id
}

output "service_principal_object_id" {
  value = module.infracost.service_principal_object_id
}

output "billing_role_assignment_id" {
  value = module.infracost.billing_role_assignment_id
}
