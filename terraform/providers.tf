# Both providers authenticate the same way as the backend: in CI with the
# GitHub OIDC token (ARM_USE_OIDC, ARM_CLIENT_ID, ARM_TENANT_ID and
# ARM_SUBSCRIPTION_ID come from the workflow), and locally with `az login`.
# There is no client secret anywhere.

provider "azurerm" {
  # The CI identities are scoped to one resource group and cannot register
  # resource providers, which is a subscription-scope action. bootstrap.sh
  # registers the ones this project needs, as a human. (none is also the
  # default from azurerm 5.0; it is set here so nobody has to know that.)
  resource_provider_registrations = "none"

  # Storage data-plane calls use Entra ID, never account keys.
  storage_use_azuread = true

  use_oidc = true

  features {
    key_vault {
      # Purging a deleted vault is a subscription-scope action
      # (Microsoft.KeyVault/locations/deletedVaults/purge/action) that the
      # APPLY identity does not hold. Purging is a human step in
      # docs/teardown.md.
      purge_soft_delete_on_destroy = false

      # Never silently resurrect a soft-deleted vault with old contents; a
      # name clash should fail loudly and be resolved by a human.
      recover_soft_deleted_key_vaults = false
    }
  }
}

provider "azapi" {
  # Same reason as azurerm's resource_provider_registrations above.
  skip_provider_registration = true

  use_oidc = true
}
