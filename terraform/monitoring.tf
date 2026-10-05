# Log Analytics workspace: where Key Vault audit events and Container Apps
# logs land.
#
# Managed with azapi, not azurerm: azurerm's refresh of a workspace reads its
# shared keys and stores them in state (log_analytics_workspace_resource.go,
# azurerm 5.8.0), and a saved plan carries state into a public artifact.
# azapi's refresh is a plain GET, which never returns keys. Local
# (shared-key) authentication is disabled anyway: nothing here ingests with
# a key; logs arrive through diagnostic settings, which use Azure's own
# identity.
resource "azapi_resource" "log_analytics" {
  type      = "Microsoft.OperationalInsights/workspaces@2025-07-01"
  name      = "log-portfolio-on-azure"
  parent_id = data.azurerm_resource_group.this.id
  location  = local.location
  tags      = local.tags

  body = {
    properties = {
      sku = {
        name = "PerGB2018"
      }

      # 30 days: inside the 31 days of retention that Analytics Logs include
      # at no charge.
      retentionInDays = 30

      # 0.1 GB/day. Even if it is hit every day, 0.1 x 31 = 3.1 GB a month,
      # under the 5 GB/month that Analytics Logs ingest free per billing
      # account, with 1.9 GB of headroom for the overshoot Microsoft says to
      # expect ("the daily cap can't stop data collection at precisely the
      # specified cap level"). Demo traffic is expected to be a few MB a day.
      # Trade-off: once the cap is hit, collection stops until the daily
      # reset, including Key Vault audit events. A production audit
      # workspace would not be capped this way.
      workspaceCapping = {
        dailyQuotaGb = 0.1
      }

      features = {
        disableLocalAuth = true
      }

      publicNetworkAccessForIngestion = "Enabled"
      publicNetworkAccessForQuery     = "Enabled"
    }
  }

  # The workspace's GUID, which KQL queries and the portal call the
  # workspace ID.
  response_export_values = ["properties.customerId"]

  # Delete permanently on destroy rather than into the 14-day soft-delete
  # state, so teardown leaves nothing behind and the name is reusable.
  delete_query_parameters = {
    force = ["true"]
  }
}
