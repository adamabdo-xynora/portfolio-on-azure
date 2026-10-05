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
