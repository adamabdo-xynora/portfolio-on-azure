# Key Vault for the apps' secrets. Terraform creates the vault and decides
# who may read it; it never holds a secret value (docs/secrets.md).
resource "azurerm_key_vault" "this" {
  name                = "kv-portfolio-on-azure"
  location            = local.location
  resource_group_name = data.azurerm_resource_group.this.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"
  tags                = local.tags

  # Azure RBAC, not access policies: who can read a secret is a role
  # assignment, visible in the same place as every other permission, and
  # covered by the APPLY identity's RBAC condition.
  rbac_authorization_enabled = true

  # Soft delete is always on for Key Vault and cannot be turned off. Seven
  # days is the minimum retention.
  soft_delete_retention_days = 7

  # Off, deliberately, for this demo: with purge protection on, a deleted
  # vault cannot be purged until its retention ends, so teardown could not
  # finish cleanly. A production deployment at a bank would turn it on.
  # Recorded in the README's trade-offs.
  purge_protection_enabled = false

  # No private endpoint (out of scope); access is controlled by Entra ID and
  # RBAC.
  public_network_access_enabled = true
}

# Every Key Vault request, including each secret read by a managed identity,
# is recorded as an AuditEvent in Log Analytics (table AzureDiagnostics).
resource "azurerm_monitor_diagnostic_setting" "key_vault" {
  name                       = "audit-to-log-analytics"
  target_resource_id         = azurerm_key_vault.this.id
  log_analytics_workspace_id = azapi_resource.log_analytics.id

  enabled_log {
    category = "AuditEvent"
  }
}
