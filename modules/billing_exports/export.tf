locals {
  cost_management_api_version = "2025-03-01"
  billing_account_resource_id = "/providers/Microsoft.Billing/billingAccounts/${var.billing_account_id}"
  export_schedule_end         = "2099-12-31T00:00:00Z"
}

resource "terraform_data" "export_schedule_start" {
  count = var.provision_billing_exports ? 1 : 0

  input = formatdate("YYYY-MM-DD'T'00:00:00Z", timeadd(plantimestamp(), "24h"))

  triggers_replace = [
    var.export_name,
    local.billing_account_resource_id,
    var.location,
  ]

  lifecycle {
    ignore_changes = [input]
  }
}

# https://learn.microsoft.com/en-us/rest/api/cost-management/exports/create-or-update?view=rest-cost-management-2025-03-01&tabs=HTTP
resource "azapi_resource" "focus_cost_export" {
  count = var.provision_billing_exports ? 1 : 0

  type      = "Microsoft.CostManagement/exports@${local.cost_management_api_version}"
  name      = var.export_name
  parent_id = local.billing_account_resource_id
  location  = var.location

  identity {
    type = "SystemAssigned"
  }

  body = {
    properties = {
      format                = "Parquet"
      compressionMode       = "snappy"
      dataOverwriteBehavior = "OverwritePreviousReport"
      partitionData         = true
      definition = {
        type      = "FocusCost"
        timeframe = "MonthToDate"
        dataSet = {
          granularity = "Daily"
          configuration = {
            dataVersion = "1.2-preview"
          }
        }
      }
      deliveryInfo = {
        destination = {
          type           = "AzureBlob"
          resourceId     = azurerm_storage_account.billing_exports[0].id
          container      = azurerm_storage_container.billing_exports[0].name
          rootFolderPath = var.root_path
        }
      }
      schedule = {
        status     = "Active"
        recurrence = "Daily"
        recurrencePeriod = {
          from = terraform_data.export_schedule_start[0].output
          to   = local.export_schedule_end
        }
      }
    }
  }

  response_export_values = ["identity.principalId"]

  lifecycle {
    precondition {
      condition     = var.billing_account_id != null
      error_message = "billing_account_id is required to create the FOCUS cost export."
    }
  }

  depends_on = [azapi_resource_action.resource_provider_registration]
}

resource "azurerm_role_assignment" "export_blob_writer" {
  count = var.provision_billing_exports ? 1 : 0

  scope                = azurerm_storage_account.billing_exports[0].id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azapi_resource.focus_cost_export[0].output.identity.principalId
  principal_type       = "ServicePrincipal"
  description          = "Infracost FOCUS cost export write access"
}
