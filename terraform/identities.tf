# One user-assigned managed identity per workload. Each Container App or Job
# reads its Key Vault secrets as its own identity, so the audit log shows
# which workload read what.
#
# Neither identity can read anything yet. Each is granted Key Vault Secrets
# User on its own secrets only, scoped to the individual secret, in the pull
# request that deploys its workload (webhook-guard: webhook-secret;
# rag-receipts: voyage-api-key, plus anthropic-api-key only if a full eval
# run is approved). A secret-scope role assignment needs the secret to exist,
# and the secrets are set by hand after this apply (docs/secrets.md), so the
# grants cannot be made here.
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
