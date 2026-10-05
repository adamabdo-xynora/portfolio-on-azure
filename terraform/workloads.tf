# The two workloads, and the name of the Key Vault each one gets.
#
# One vault per workload, following Microsoft's Key Vault RBAC guidance: "use
# a vault per application per environment ... with roles assigned at the key
# vault scope" (https://learn.microsoft.com/en-us/azure/key-vault/general/rbac-guide).
# Each workload's managed identity can read only its own vault, so neither
# workload can read the other's secrets. See docs/identities.md.
#
# Vault names are global and at most 24 characters; both were confirmed
# available with Microsoft.KeyVault/checkNameAvailability on 2026-10-05.
locals {
  workloads = {
    "webhook-guard" = {
      key_vault_name = "kv-poa-webhook-guard"
    }
    "rag-receipts" = {
      key_vault_name = "kv-poa-rag-receipts"
    }
  }
}
