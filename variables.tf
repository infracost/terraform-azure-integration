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

variable "billing_agreement_type" {
  description = "Billing agreement of the billing account where Infracost gets read access to billing data. EA assigns EnrollmentReader on the enrollment. MCA assigns Billing account reader on the billing account."
  type        = string
  nullable    = false

  validation {
    condition     = contains(["EA", "MCA"], var.billing_agreement_type)
    error_message = "billing_agreement_type must be EA or MCA."
  }
}

variable "billing_account_id" {
  description = "ID of the billing account. For EA, this is the enrollment number. For MCA, this is the billing account ID in the format <guid>:<guid>_<yyyy-mm-dd>."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^([0-9]+|[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}:[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}_[0-9]{4}-[0-9]{2}-[0-9]{2})$", var.billing_account_id))
    error_message = "billing_account_id must be an EA enrollment number or an MCA billing account ID."
  }
}
