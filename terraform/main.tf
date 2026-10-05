# The resource group belongs to bootstrap.sh, not to Terraform. Everything
# Terraform creates goes into it, in its region, with its tags.
data "azurerm_resource_group" "this" {
  name = var.resource_group_name
}

data "azurerm_client_config" "current" {}

locals {
  location = data.azurerm_resource_group.this.location

  # Applied to every resource Terraform creates. The resource group carries
  # the same three tags, set by bootstrap.sh.
  tags = {
    project = "portfolio-on-azure"
    owner   = "adam"
    env     = "demo"
  }
}
