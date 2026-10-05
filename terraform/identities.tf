# One user-assigned managed identity per workload. Each Container App or Job
# reads its Key Vault secrets as its own identity, so the audit log shows
# which workload read what.
resource "azurerm_user_assigned_identity" "webhook_guard" {
  name                = "id-webhook-guard"
  location            = local.location
  resource_group_name = data.azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_user_assigned_identity" "rag_receipts" {
  name                = "id-rag-receipts"
  location            = local.location
  resource_group_name = data.azurerm_resource_group.this.name
  tags                = local.tags
}

# Key Vault Secrets User: read secret values, nothing else. These are the
# only role assignments the APPLY identity is allowed to make: its RBAC
# Administrator role carries a condition that admits this one role, granted
# to service principals only. principal_type must be set explicitly, or the
# request carries no principal type and that condition denies it.
#
# Scope is the vault, so each identity can read every secret in it. Narrower
# scopes (one vault per workload, or assignments on individual secrets) are
# the production choice; see the README's trade-offs.
resource "azurerm_role_assignment" "webhook_guard_secrets" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.webhook_guard.principal_id
  principal_type       = "ServicePrincipal"
  description          = "webhook-guard reads its signing secret from Key Vault"
}

resource "azurerm_role_assignment" "rag_receipts_secrets" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.rag_receipts.principal_id
  principal_type       = "ServicePrincipal"
  description          = "rag-receipts reads its API keys from Key Vault"
}
