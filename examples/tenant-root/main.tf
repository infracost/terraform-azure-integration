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

variable "enable_top_level_billing_access" {
  description = "Assign a billing reader role on the whole billing account. Set to false if you cannot assign billing roles."
  type        = bool
  default     = true
}

variable "billing_agreement_type" {
  description = "Billing agreement of the billing account: EA or MCA."
  type        = string
  default     = null
}

variable "billing_account_id" {
  description = "ID of the EA enrollment or MCA billing account."
  type        = string
  default     = null
}

variable "billing_exports_location" {
  description = "Azure region of the billing exports storage account."
  type        = string
  default     = null
}

variable "enable_billing_exports" {
  description = "Give Infracost read access to a daily FOCUS cost export."
  type        = bool
  default     = true
}

variable "provision_billing_exports" {
  description = "Create the storage account and FOCUS cost export."
  type        = bool
  default     = true
}

variable "existing_billing_exports" {
  description = "Existing FOCUS cost export destination."
  type = object({
    storage_account_id = string
    container          = string
    root_path          = string
  })
  default = null
}

module "infracost" {
  source = "../.."

  infracost_client_id             = var.infracost_client_id
  enable_top_level_billing_access = var.enable_top_level_billing_access
  billing_agreement_type          = var.billing_agreement_type
  billing_account_id              = var.billing_account_id
  billing_exports_location        = var.billing_exports_location
  enable_billing_exports          = var.enable_billing_exports
  provision_billing_exports       = var.provision_billing_exports
  existing_billing_exports        = var.existing_billing_exports
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

output "billing_exports" {
  value = module.infracost.billing_exports
}
