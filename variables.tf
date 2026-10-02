variable "infracost_client_id" {
  description = "Client ID of the Infracost multi-tenant application. Do not change this."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.infracost_client_id))
    error_message = "infracost_client_id must be a GUID."
  }
}

variable "management_group_names" {
  description = "Names of the management groups where Infracost gets read-only access. If empty, the tenant root management group is used, which covers all subscriptions in the tenant."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for name in var.management_group_names : trimspace(name) != ""])
    error_message = "management_group_names must not contain empty names."
  }
}

variable "role_definition_names" {
  description = "Built-in roles assigned to the Infracost service principal at the management group scope."
  type        = list(string)
  default     = ["Reader", "Cost Management Reader", "Monitoring Reader"]
}

variable "service_principal_owners" {
  description = "Object IDs of principals that own the Infracost service principal. Set this to the principal running Terraform when it only has Application.ReadWrite.OwnedBy. If null, the service principal has no owners."
  type        = list(string)
  default     = null

  validation {
    condition     = var.service_principal_owners == null || alltrue([for object_id in coalesce(var.service_principal_owners, []) : can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", object_id))])
    error_message = "service_principal_owners must contain object ID GUIDs."
  }
}

variable "enable_top_level_billing_access" {
  description = "Assign a billing reader role on the whole billing account. This gives Infracost read access to all charges, invoices and price sheets of the billing account, beyond the management groups in management_group_names. Recommended. Set to false if the principal running Terraform cannot assign billing roles."
  type        = bool
  default     = true
  nullable    = false
}

variable "billing_agreement_type" {
  description = "Billing agreement of the billing account where Infracost gets read access to billing data. EA assigns EnrollmentReader on the enrollment. MCA assigns Billing account reader on the billing account. Required if enable_top_level_billing_access is true."
  type        = string
  default     = null

  validation {
    condition     = !var.enable_top_level_billing_access || var.billing_agreement_type != null
    error_message = "billing_agreement_type is required when enable_top_level_billing_access is true."
  }
}

variable "billing_account_id" {
  description = "ID of the billing account. For EA, this is the enrollment number. For MCA, this is the billing account ID in the format <guid>:<guid>_<yyyy-mm-dd>."
  type        = string
  default     = null

  validation {
    condition     = !(var.enable_top_level_billing_access || (var.enable_billing_exports && var.provision_billing_exports)) || var.billing_account_id != null
    error_message = "billing_account_id is required when enable_top_level_billing_access is true, or when enable_billing_exports and provision_billing_exports are true."
  }
}

variable "enable_billing_exports" {
  description = "Give Infracost read access to a daily FOCUS cost export of the billing account."
  type        = bool
  default     = true
  nullable    = false
}

variable "provision_billing_exports" {
  description = "Create the storage account and FOCUS cost export. If false, existing_billing_exports is used."
  type        = bool
  default     = true
  nullable    = false
}

variable "existing_billing_exports" {
  description = "Existing FOCUS cost export destination that Infracost reads."
  type = object({
    storage_account_id = string
    container          = string
    root_path          = string
  })
  default = null

  validation {
    condition     = !var.enable_billing_exports || var.provision_billing_exports || var.existing_billing_exports != null
    error_message = "existing_billing_exports is required when enable_billing_exports is true and provision_billing_exports is false."
  }
}

variable "billing_exports_location" {
  description = "Azure region of the billing exports storage account."
  type        = string
  default     = null

  validation {
    condition     = !(var.enable_billing_exports && var.provision_billing_exports) || var.billing_exports_location != null
    error_message = "billing_exports_location is required when enable_billing_exports and provision_billing_exports are true."
  }
}

variable "billing_exports_resource_group_name" {
  description = "Name of the billing exports resource group."
  type        = string
  default     = "infracost-billing-exports"
  nullable    = false
}

variable "billing_exports_storage_account_name" {
  description = "Globally unique name of the billing exports storage account. Derived from the tenant ID if null."
  type        = string
  default     = null
}
