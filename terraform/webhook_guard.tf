# webhook-guard: the HTTPS webhook receiver, as a Container App.
#
# Managed with azapi, not azurerm: azurerm's refresh of a Container App calls
# listSecrets, which Microsoft documents as returning secret values in plain
# text. The PLAN identity holds only Reader, and azapi's refresh is a plain
# GET, which never returns secret values. See docs/identities.md
# ("Correction (2026-10-04)").
#
# The image is pinned by the digest of its signed multi-arch index
# (images.json), verified against its SLSA provenance by
# scripts/verify_images.sh in CI before any plan or apply.
locals {
  webhook_guard_image = jsondecode(file("${path.module}/../images.json"))["webhook-guard"]
}

resource "azapi_resource" "webhook_guard" {
  type      = "Microsoft.App/containerApps@2025-07-01"
  name      = "ca-webhook-guard"
  parent_id = data.azurerm_resource_group.this.id
  location  = local.location
  tags      = merge(local.tags, { workload = "webhook-guard" })

  # Runs as its own user-assigned identity, which is Key Vault Secrets User
  # on kv-poa-webhook-guard only (terraform/identities.tf).
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.workload["webhook-guard"].id]
  }

  body = {
    properties = {
      environmentId       = azurerm_container_app_environment.this.id
      workloadProfileName = "Consumption"

      configuration = {
        activeRevisionsMode = "Single"

        # Public HTTPS. Plain HTTP is redirected, never served.
        ingress = {
          external      = true
          targetPort    = 8080
          transport     = "Auto"
          allowInsecure = false
          traffic = [{
            latestRevision = true
            weight         = 100
          }]
        }

        # A Key Vault reference, not a value: the versionless secret URL and
        # the identity to fetch it with. The platform reads the current
        # version when a revision starts and refreshes it periodically; each
        # read is a Key Vault AuditEvent.
        secrets = [{
          name        = "webhook-secret"
          keyVaultUrl = "${azurerm_key_vault.workload["webhook-guard"].vault_uri}secrets/webhook-secret"
          identity    = azurerm_user_assigned_identity.workload["webhook-guard"].id
        }]
      }

      template = {
        containers = [{
          name  = "webhook-guard"
          image = "${local.webhook_guard_image.image}@${local.webhook_guard_image.digest}"

          # The smallest Consumption allocation.
          resources = {
            cpu    = 0.25
            memory = "0.5Gi"
          }

          # The receiver refuses to start without WEBHOOK_SECRET (exit 1).
          env = [{
            name      = "WEBHOOK_SECRET"
            secretRef = "webhook-secret"
          }]

          # GET /healthz answers 200 without authentication and touches no
          # state (src/server.ts). Health probe requests are not billed.
          probes = [
            {
              type = "Liveness"
              httpGet = {
                path = "/healthz"
                port = 8080
              }
              periodSeconds    = 30
              failureThreshold = 3
            },
            {
              type = "Readiness"
              httpGet = {
                path = "/healthz"
                port = 8080
              }
              periodSeconds    = 10
              failureThreshold = 3
            },
          ]
        }]

        # Scale to zero when idle; no charge while at zero. At most one
        # replica: the receiver's dedup store and archive live on the
        # replica's own disk, so a second replica would dedup independently.
        # That disk is also lost on scale-in, which is acceptable for this
        # demo and recorded in docs/identities.md (trade-offs).
        scale = {
          minReplicas = 0
          maxReplicas = 1
        }
      }
    }
  }

  response_export_values = [
    "properties.configuration.ingress.fqdn",
    "properties.latestRevisionName",
  ]
}
