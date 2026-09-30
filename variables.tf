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
  description = "ID of the billing account. For EA, this is the enrollment number. For MCA, this is the billing account ID in the format <guid>:<guid>_<yyyy-mm-dd>. Required if enable_top_level_billing_access is true."
  type        = string
  default     = null

  validation {
    condition     = !var.enable_top_level_billing_access || var.billing_account_id != null
    error_message = "billing_account_id is required when enable_top_level_billing_access is true."
  }
}
