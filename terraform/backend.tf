# Remote state in the storage account bootstrap.sh created. The account has
# shared keys disabled, so the backend authenticates with Entra ID only:
# use_azuread_auth for the blob data plane, use_oidc for the GitHub Actions
# token exchange. State locking is a blob lease, taken automatically.
#
# Identifiers here are not secrets; whoever reads this still needs a role on
# the container (docs/identities.md) to read or write state.
terraform {
  backend "azurerm" {
    resource_group_name  = "rg-portfolio-on-azure"
    storage_account_name = "stportfolioazuretf"
    container_name       = "tfstate"
    key                  = "portfolio-on-azure.tfstate"
    use_azuread_auth     = true
    use_oidc             = true
  }
}
