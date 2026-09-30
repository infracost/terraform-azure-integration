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

variable "service_principal_object_id" {
  description = "Object ID of the service principal that gets the billing reader role."
  type        = string
  nullable    = false
}

variable "service_principal_tenant_id" {
  description = "Tenant ID of the service principal that gets the billing reader role."
  type        = string
  nullable    = false
}
