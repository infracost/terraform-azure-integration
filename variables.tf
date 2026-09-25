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
