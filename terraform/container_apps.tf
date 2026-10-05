# Container Apps environment, Consumption only.
#
# No workload_profile block, which makes this the Consumption-only
# environment type. Microsoft's documentation calls that type legacy, and
# says of it: "There's no cost associated with the Container Apps
# environment." Workload-profile environments bill a management fee for
# Dedicated profiles, private endpoints, and planned maintenance (meter
# "Environment Management Hour", C$0.17/hour in canadacentral from
# 2026-09-01). This project uses none of those, and chooses the type whose
# environment cost Microsoft states as zero. A production deployment would
# use a workload-profiles environment. The type cannot be changed later
# without recreating the environment.
#
# Logs go to Azure Monitor and from there, through the diagnostic setting
# below, to Log Analytics. The log-analytics destination would instead
# need the workspace's shared key, which is disabled.
resource "azurerm_container_app_environment" "this" {
  name                = "cae-portfolio-on-azure"
  location            = local.location
  resource_group_name = data.azurerm_resource_group.this.name
  logs_destination    = "azure-monitor"
  tags                = local.tags
}

resource "azurerm_monitor_diagnostic_setting" "container_apps" {
  name                       = "logs-to-log-analytics"
  target_resource_id         = azurerm_container_app_environment.this.id
  log_analytics_workspace_id = azapi_resource.log_analytics.id

  enabled_log {
    category = "ContainerAppConsoleLogs"
  }

  enabled_log {
    category = "ContainerAppSystemLogs"
  }
}
