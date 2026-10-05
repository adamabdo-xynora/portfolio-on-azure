# Container Apps environment: workload-profiles type, Consumption profile only.
#
# Correction (2026-10-05): this environment was first declared with no
# workload_profile block, on the belief that this creates the legacy
# "Consumption only" environment type. It does not. azurerm 5.8.0 creates
# environments with Microsoft.App API version 2025-07-01, and Azure created a
# workload-profiles environment with a single Consumption profile, the type
# Microsoft documents as the default. The profile is now declared here so the
# configuration matches what exists. See docs/identities.md.
#
# Cost: workload-profiles environments carry an hourly management charge
# (meter "Environment Management Hour", C$0.17/hour in canadacentral) only
# for Dedicated profiles, private endpoints and planned maintenance.
# Microsoft's Container Apps billing documentation: "You aren't billed any
# plan management charges unless you use a Dedicated workload profile in
# your environment." This environment has no Dedicated profile, no private
# endpoint and no maintenance configuration, so the environment itself is
# expected to cost nothing; apps and jobs pay per second of use. To be
# confirmed from actual usage data.
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

  # The Consumption profile only: serverless, scale to zero, billed per
  # second of use. No Dedicated profile, so no plan management charge.
  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }
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
