output "role_assignment_id" {
  description = "ID of the billing role assignment on the billing account: EnrollmentReader for EA, Billing account reader for MCA."
  value       = var.billing_agreement_type == "EA" ? azapi_resource.enrollment_reader[0].id : local.billing_account_reader_assignment_resource_id
}
