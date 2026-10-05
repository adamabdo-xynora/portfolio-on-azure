# portfolio-on-azure

Infrastructure for running two of my public projects on Azure Container Apps:
[webhook-guard](https://github.com/adamabdo-xynora/webhook-guard) as an HTTPS
service and [rag-receipts](https://github.com/adamabdo-xynora/rag-receipts) as
a manually triggered job. Terraform, keyless OIDC CI/CD, secrets in Key Vault
read through managed identities, audit logs, and cost controls.

**Status: being built, one reviewed pull request at a time.** This README is
written last, after each claim in it has been verified against the running
deployment. Until then:

- [`bootstrap/`](bootstrap/): what Terraform cannot create for itself
- [`docs/identities.md`](docs/identities.md): every identity, role and scope, and why
- [`docs/ci.md`](docs/ci.md): the plan/apply pipeline, and what its public logs and artifacts contain
- [`docs/secrets.md`](docs/secrets.md): how secret values are set without touching Terraform, GitHub or this repo
- [`docs/verification.md`](docs/verification.md): what must be proven before this README claims it
- [`docs/teardown.md`](docs/teardown.md): how to remove all of it

## Cost

Written before the first apply of each pull request that adds billable
resources. Prices are retail, in **CAD** (the billing currency), for
**canadacentral**, read on **2026-10-04** from Microsoft's
[Azure Retail Prices API](https://prices.azure.com/api/retail/prices) and the
pricing pages linked below. They are estimates; Cost Management shows what
was actually charged.

The subscription is an Azure free account with its **spending limit on**.
That limit is the actual cap on spend. The budget below only sends alerts,
and cost data lags usage by 8–24 hours.

### Bootstrap (created by `bootstrap/bootstrap.sh`)

| Resource | SKU / tier | Pricing model | Free grant | Expected monthly cost at demo usage |
|---|---|---|---|---|
| Storage account `stportfolioazuretf` (Terraform state) | Standard LRS, StorageV2, Hot | C$0.0283/GB-month stored; C$0.0779 per 10k writes; C$0.0062 per 10k reads and other ops | none assumed | **< C$0.05**: state is a few KB, plus a few thousand operations from CI runs |
| Entra app registrations ×2, role assignments, resource provider registrations | n/a | no charge | n/a | **C$0.00** |

### PR 3: shared resources

| Resource | SKU / tier | Pricing model | Free grant | Expected monthly cost at demo usage |
|---|---|---|---|---|
| Log Analytics workspace `log-portfolio-on-azure` | Pay-as-you-go (PerGB2018), Analytics Logs, 30-day retention, **0.1 GB/day cap** | C$3.9097/GB ingested after the free 5 GB; retention C$0.17/GB-month beyond the included 31 days | **5 GB/month ingestion per billing account; 31 days retention included** | **C$0.00**: expected ingestion is well under 1 GB a month, and the cap holds the worst case to about 3.1 GB |
| Key Vault `kv-portfolio-on-azure` | Standard | C$0.0425 per 10,000 secret operations; no monthly fee per vault | none | **< C$0.05**: a few thousand reads (the apps refresh their secret references; CI refreshes metadata) |
| Diagnostic settings ×2 (Key Vault audit, Container Apps logs) | n/a | no charge for the setting; the logs are billed as Log Analytics ingestion above | — | **C$0.00** (counted under Log Analytics) |
| User-assigned managed identities ×2 | n/a | no charge | n/a | **C$0.00** |
| Container Apps environment `cae-portfolio-on-azure` | **Consumption only**: no workload profiles, no private endpoint, no planned maintenance | Microsoft: *"There's no cost associated with the Container Apps environment"* for this type. The C$0.17/hour "Environment Management Hour" meter (from 2026-09-01) *"applies to the Dedicated plan, private endpoint, and planned maintenance"*, none of which is used | n/a | **C$0.00** (to be confirmed from actual usage data about 24 hours after the apply) |
| Budget `budget-portfolio-on-azure` | C$10/month, alerts at 50/80/100% of actual cost | no charge | n/a | **C$0.00** |

**PR 3 total: under C$0.10 a month**, mostly Key Vault and storage
operations. Nothing in it needs the free account upgraded.

**Why the Log Analytics daily cap is 0.1 GB.** 0.1 GB × 31 days = 3.1 GB, under
the 5 GB/month free ingestion, with 1.9 GB of headroom because Microsoft
says the cap "can't stop data collection at precisely the specified cap
level" and data above it is still billed. Demo traffic is a few MB a day.
The cost of the cap: once it is reached, collection stops until the
workspace's daily reset, including Key Vault audit events. A bank would not
cap an audit workspace this way.

PR 4 (webhook-guard) and PR 5 (rag-receipts job) add their rows here before
their first apply, including their per-secret Key Vault role assignments
(no charge).

Sources, all read 2026-10-04:
[Container Apps pricing](https://azure.microsoft.com/en-us/pricing/details/container-apps/),
[Container Apps environment types](https://learn.microsoft.com/en-us/azure/container-apps/environment),
[Container Apps billing](https://learn.microsoft.com/en-us/azure/container-apps/billing),
[Azure Monitor pricing](https://azure.microsoft.com/en-us/pricing/details/monitor/),
[Log Analytics daily cap](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/daily-cap),
[Key Vault pricing](https://azure.microsoft.com/en-us/pricing/details/key-vault/),
[Blob Storage pricing](https://azure.microsoft.com/en-us/pricing/details/storage/blobs/),
[Cost Management data latency](https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/understand-cost-mgt-data),
and the [Azure Retail Prices API](https://prices.azure.com/api/retail/prices)
(`currencyCode=CAD`, `armRegionName=canadacentral`).
