variable "service_principal_object_id" {
  description = "Object ID of the service principal that gets read access to the billing exports."
  type        = string
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
    condition     = var.provision_billing_exports || var.existing_billing_exports != null
    error_message = "existing_billing_exports is required when provision_billing_exports is false."
  }

  validation {
    condition     = var.existing_billing_exports == null || can(regex("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.Storage/storageAccounts/[^/]+$", var.existing_billing_exports.storage_account_id))
    error_message = "existing_billing_exports.storage_account_id must be a storage account resource ID."
  }
}

variable "billing_account_id" {
  description = "ID of the billing account where the FOCUS cost export is created."
  type        = string
  default     = null
}

variable "subscription_id" {
  description = "ID of the subscription that hosts the storage account."
  type        = string
  nullable    = false
}

variable "location" {
  description = "Azure region of the storage account and cost export."
  type        = string
  default     = null

  validation {
    condition     = !var.provision_billing_exports || var.location != null
    error_message = "location is required when provision_billing_exports is true."
  }
}

variable "resource_group_name" {
  description = "Name of the resource group that contains the storage account."
  type        = string
  nullable    = false
}

variable "storage_account_name" {
  description = "Globally unique name of the storage account."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.storage_account_name))
    error_message = "storage_account_name must be 3 to 24 lowercase letters and numbers."
  }
}

variable "container_name" {
  description = "Name of the blob container that receives the cost export."
  type        = string
  default     = "infracost-exports"
  nullable    = false
}

variable "root_path" {
  description = "Folder path in the container for the cost export files."
  type        = string
  default     = "focus-cost"
  nullable    = false
}

variable "cold_tier_after_days" {
  description = "Number of days after the last modification before billing export files move to the cold tier."
  type        = number
  default     = 90
  nullable    = false

  validation {
    condition     = var.cold_tier_after_days >= 0 && floor(var.cold_tier_after_days) == var.cold_tier_after_days
    error_message = "cold_tier_after_days must be a whole number of 0 or more."
  }
}

variable "retention_days" {
  description = "Number of days after the last modification before billing export files are deleted."
  type        = number
  default     = 365
  nullable    = false

  validation {
    condition     = var.retention_days > var.cold_tier_after_days && var.retention_days <= 99999 && floor(var.retention_days) == var.retention_days
    error_message = "retention_days must be a whole number greater than cold_tier_after_days and at most 99999."
  }
}

variable "export_name" {
  description = "Name of the FOCUS cost export."
  type        = string
  default     = "InfracostDailyFocusExport"
  nullable    = false
}

variable "tags" {
  description = "Tags applied to the created resources."
  type        = map(string)
  default     = {}
}
