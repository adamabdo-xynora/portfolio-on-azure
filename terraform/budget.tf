# C$10 a month for the resource group, with email alerts at 50%, 80% and
# 100% of actual cost. The amount is in the billing account's currency
# (CAD); the Budgets API has no currency field.
#
# A budget alerts; it does not stop spending. Cost data lags usage by 8-24
# hours on this account type, so an alert arrives after the cost. The hard
# limit on this subscription is the free account's spending limit, which is
# on (bootstrap.sh refuses to run otherwise).
#
# Alerts go to whoever holds the Owner role, rather than to an address
# written here: this repository and its plan output are public.
resource "azurerm_consumption_budget_resource_group" "this" {
  name              = "budget-portfolio-on-azure"
  resource_group_id = data.azurerm_resource_group.this.id
  amount            = 10
  time_grain        = "Monthly"

  time_period {
    # Must be the first of a month; the budget runs 10 years by default.
    start_date = "2026-10-01T00:00:00Z"
  }

  dynamic "notification" {
    for_each = [50, 80, 100]
    content {
      enabled        = true
      threshold      = notification.value
      operator       = "GreaterThanOrEqualTo"
      threshold_type = "Actual"
      contact_roles  = ["Owner"]
    }
  }
}
