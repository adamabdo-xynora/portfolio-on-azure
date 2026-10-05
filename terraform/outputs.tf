output "resource_group_id" {
  description = "The resource group every resource lives in."
  value       = data.azurerm_resource_group.this.id
}

output "location" {
  description = "Region of the resource group, used for every resource."
  value       = local.location
}

output "log_analytics_workspace_id" {
  description = "Resource ID of the Log Analytics workspace."
  value       = azapi_resource.log_analytics.id
}

output "log_analytics_customer_id" {
  description = "The workspace GUID used by KQL tools (az monitor log-analytics query --workspace)."
  value       = azapi_resource.log_analytics.output.properties.customerId
}

output "workloads" {
  description = "Per workload: its Key Vault (secret values are set by hand, docs/secrets.md) and the managed identity that reads it."
  value = {
    for name, _ in local.workloads : name => {
      key_vault_name        = azurerm_key_vault.workload[name].name
      key_vault_uri         = azurerm_key_vault.workload[name].vault_uri
      identity_id           = azurerm_user_assigned_identity.workload[name].id
      identity_principal_id = azurerm_user_assigned_identity.workload[name].principal_id
    }
  }
}

output "container_app_environment_id" {
  description = "Container Apps environment (Consumption profile only)."
  value       = azurerm_container_app_environment.this.id
}
