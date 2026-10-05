output "resource_group_id" {
  description = "The resource group every resource lives in."
  value       = data.azurerm_resource_group.this.id
}

output "location" {
  description = "Region of the resource group, used for every resource."
  value       = local.location
}

output "deploying_identity_object_id" {
  description = "Object ID of the identity that ran this plan or apply: the PLAN or APPLY service principal in CI."
  value       = data.azurerm_client_config.current.object_id
}

output "log_analytics_workspace_id" {
  description = "Resource ID of the Log Analytics workspace."
  value       = azapi_resource.log_analytics.id
}

output "log_analytics_customer_id" {
  description = "The workspace GUID used by KQL tools (az monitor log-analytics query --workspace)."
  value       = azapi_resource.log_analytics.output.properties.customerId
}

output "key_vault_name" {
  description = "Vault that holds the apps' secrets. Values are set by hand (docs/secrets.md)."
  value       = azurerm_key_vault.this.name
}

output "key_vault_uri" {
  description = "Base URI for the apps' Key Vault references."
  value       = azurerm_key_vault.this.vault_uri
}

output "webhook_guard_identity" {
  description = "Managed identity webhook-guard reads its secret with."
  value = {
    id           = azurerm_user_assigned_identity.webhook_guard.id
    principal_id = azurerm_user_assigned_identity.webhook_guard.principal_id
  }
}

output "rag_receipts_identity" {
  description = "Managed identity the rag-receipts job reads its keys with."
  value = {
    id           = azurerm_user_assigned_identity.rag_receipts.id
    principal_id = azurerm_user_assigned_identity.rag_receipts.principal_id
  }
}

output "container_app_environment_id" {
  description = "Consumption-only Container Apps environment."
  value       = azurerm_container_app_environment.this.id
}
