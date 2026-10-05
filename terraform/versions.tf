terraform {
  # CI installs exactly this version (hashicorp/setup-terraform), so a plan
  # saved by one job is applied by the same Terraform in the next.
  required_version = "~> 1.16.4"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.8.0"
    }
    # For resources whose azurerm refresh would read secret material: the
    # Log Analytics workspace (shared keys) and the Container App and Job
    # (listSecrets). azapi's refresh is a plain GET. See docs/identities.md.
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.13.0"
    }
  }
}
