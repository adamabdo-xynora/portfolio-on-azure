# One user-assigned managed identity per workload. Each Container App or Job
# reads its Key Vault secrets as its own identity, so the audit log shows
# which workload read what.
resource "azurerm_user_assigned_identity" "workload" {
  for_each = local.workloads

  name                = "id-${each.key}"
  location            = local.location
  resource_group_name = data.azurerm_resource_group.this.name
  tags                = merge(local.tags, { workload = each.key })
}

# Key Vault Secrets User on the workload's own vault, and nowhere else: read
# secret values, nothing more. Granted here, with the vaults, so the grants
# exist before any secret is set or any app references one.
#
# This is the only role the APPLY identity may assign: its RBAC
# Administrator role carries a condition that admits Key Vault Secrets User,
# granted to service principals only. principal_type must be set
# explicitly, or the request carries no principal type and the condition
# denies it.
resource "azurerm_role_assignment" "workload_secrets" {
  for_each = local.workloads

  scope                = azurerm_key_vault.workload[each.key].id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.workload[each.key].principal_id
  principal_type       = "ServicePrincipal"
  description          = "${each.key} reads its own secrets from ${each.value.key_vault_name}"
}
