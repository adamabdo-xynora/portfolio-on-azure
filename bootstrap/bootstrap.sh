#!/usr/bin/env bash
#
# bootstrap/bootstrap.sh: everything Terraform cannot create for itself.
#
# Terraform needs somewhere to keep its state before it can run, and CI needs
# identities to log in with before it can run Terraform. Neither can be made
# by the Terraform that depends on them, so this script makes them, once, run
# by a human who is logged in with `az login` and holds Owner on the
# subscription. CI never runs this file.
#
# What it creates (all idempotent: re-running it changes nothing that is
# already correct, and repairs anything that has drifted):
#
#   1. Resource provider registrations the deployment needs (subscription
#      scope: the CI identities are scoped to one resource group and cannot do
#      this, which is also why Terraform's own auto-registration is off).
#   2. The resource group. Terraform reads it as a data source and never
#      manages it, so `terraform destroy` cannot delete the group that holds
#      its own state.
#   3. The state storage account, its blob service settings, the state
#      container, and a CanNotDelete lock on the account.
#   4. Two Entra app registrations, PLAN and APPLY, with service principals
#      and GitHub OIDC federated credentials. Neither gets a client secret or
#      a certificate; the script checks and refuses to continue if one exists.
#   5. One custom role, assignable only inside the resource group, holding the
#      two listSecrets actions the PLAN identity needs to refresh Container
#      Apps. See docs/identities.md for why Reader alone is not enough.
#   6. Role assignments for both identities, all at resource-group scope or
#      below. Nothing is assigned at subscription scope.
#   7. Storage Blob Data Reader for you on the state container, so you can
#      audit state (verification step 8) without being able to write it.
#
# What it does NOT create: anything holding a secret value. The Key Vault,
# managed identities and apps come from Terraform; secret values are set by
# hand (docs/secrets.md). The Key Vault Secrets Officer assignment for you is a
# separate one-line command run after the shared-resources apply, because the
# vault does not exist yet when this runs.
#
# Usage:
#   az login
#   ./bootstrap/bootstrap.sh
#
# Every value below is an identifier, not a credential. A subscription ID, a
# tenant ID or a client ID lets nobody in; the federated credentials below
# decide who can exchange a GitHub token for an Azure one.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

readonly SUBSCRIPTION_ID="8e03f5b9-58e3-4036-9ded-0893a09fe1e1"
readonly TENANT_ID="4f2b53e0-95e0-473a-aeb3-1b4dd425d486"
readonly LOCATION="canadacentral"

readonly RESOURCE_GROUP="rg-portfolio-on-azure"
readonly STATE_ACCOUNT="stportfolioazuretf"
readonly STATE_CONTAINER="tfstate"
readonly STATE_LOCK_NAME="do-not-delete-terraform-state"

readonly GITHUB_REPO="adamabdo-xynora/portfolio-on-azure"
readonly DEPLOY_ENVIRONMENT="azure-demo"

# GitHub issues this repository's OIDC tokens with immutable subject claims:
# owner and repository carry their numeric IDs, so a repository deleted and
# re-created under the same name cannot reuse these credentials. The prefix is
# read from the repository's own settings:
#   gh api repos/adamabdo-xynora/portfolio-on-azure/actions/oidc/customization/sub
# and checked again below whenever gh is available.
readonly OIDC_SUBJECT_PREFIX="repo:adamabdo-xynora@276160212/portfolio-on-azure@1404957986"
readonly OIDC_ISSUER="https://token.actions.githubusercontent.com"
readonly OIDC_AUDIENCE="api://AzureADTokenExchange"

readonly PLAN_APP_NAME="github-portfolio-on-azure-plan"
readonly APPLY_APP_NAME="github-portfolio-on-azure-apply"
readonly SECRET_REF_ROLE_NAME="Container Apps Secret Reference Reader (portfolio-on-azure)"

readonly TAGS=(project=portfolio-on-azure owner=adam env=demo)

# Built-in role definition IDs. These GUIDs are the same in every tenant.
readonly ROLE_READER="acdd72a7-3385-48ef-bd42-f606fba81ae7"
readonly ROLE_CONTRIBUTOR="b24988ac-6180-42a0-ab88-20f7382dd24c"
readonly ROLE_BLOB_DATA_CONTRIBUTOR="ba92f5b4-2d11-453d-a403-e96b0029c9fe"
readonly ROLE_BLOB_DATA_READER="2a2b9908-6ea1-4ae2-8e65-a410df84e7d1"
readonly ROLE_RBAC_ADMIN="f58310d9-a9f6-439a-9e8d-f62e7b41a168"
readonly ROLE_KV_SECRETS_USER="4633458b-17de-408a-b874-0445c86b69e6"

readonly PROVIDERS=(
  Microsoft.App
  Microsoft.OperationalInsights
  Microsoft.KeyVault
  Microsoft.Insights
  Microsoft.ManagedIdentity
  Microsoft.Storage
  Microsoft.Consumption
  Microsoft.CostManagement
)

# The APPLY identity may create role assignments, but only of one role, to one
# kind of principal. Both halves are needed: the write half limits what it can
# grant, the delete half limits what it can revoke, so `terraform destroy` can
# remove the assignments it made and nothing else. @Request is the assignment
# being created; @Resource is the assignment being deleted. Terraform must set
# principal_type = "ServicePrincipal" on these assignments, or the request
# carries no PrincipalType and the condition denies it.
readonly RBAC_ADMIN_CONDITION="((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${ROLE_KV_SECRETS_USER}} AND @Request[Microsoft.Authorization/roleAssignments:PrincipalType] ForAnyOfAnyValues:StringEqualsIgnoreCase {'ServicePrincipal'})) AND ((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${ROLE_KV_SECRETS_USER}} AND @Resource[Microsoft.Authorization/roleAssignments:PrincipalType] ForAnyOfAnyValues:StringEqualsIgnoreCase {'ServicePrincipal'}))"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

WORK_DIR="$(mktemp -d)"
readonly WORK_DIR
trap 'rm -rf "$WORK_DIR"' EXIT

log() { printf '\n==> %s\n' "$*"; }
ok() { printf '    ok: %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# Retry a command a few times. Entra and ARM are eventually consistent: a
# service principal or a custom role created a second ago can be "not found"
# by the role assignment API for a short while.
retry() {
  local attempt
  for attempt in 1 2 3 4 5 6; do
    if "$@"; then return 0; fi
    printf '    (attempt %s failed; waiting for replication)\n' "$attempt" >&2
    sleep $((attempt * 10))
  done
  return 1
}

# Strip whitespace so a condition string compares equal after Azure stores it.
squash() { tr -d '[:space:]' <<<"$1"; }

# ---------------------------------------------------------------------------
# 0. Preflight: right tenant, right subscription, right repository.
# ---------------------------------------------------------------------------

preflight() {
  log "Preflight"
  command -v az >/dev/null || die "Azure CLI not found"

  az account set --subscription "$SUBSCRIPTION_ID"
  local tenant user quota spending
  tenant="$(az account show --query tenantId -o tsv)"
  [[ "$tenant" == "$TENANT_ID" ]] || die "logged in to tenant $tenant, expected $TENANT_ID"
  user="$(az account show --query user.name -o tsv)"
  ok "subscription $SUBSCRIPTION_ID, tenant $TENANT_ID, signed in as $user"

  # Refuse to run anywhere but the free-trial subscription with its spending
  # limit on: that limit is the real cost cap for this project.
  quota="$(az rest --method get \
    --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}?api-version=2022-12-01" \
    --query subscriptionPolicies.quotaId -o tsv)"
  spending="$(az rest --method get \
    --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}?api-version=2022-12-01" \
    --query subscriptionPolicies.spendingLimit -o tsv)"
  [[ "$spending" == "On" ]] || die "spending limit is '$spending'; this project assumes it is On"
  ok "offer $quota, spending limit $spending"

  if command -v gh >/dev/null; then
    local prefix
    if prefix="$(gh api "repos/${GITHUB_REPO}/actions/oidc/customization/sub" --jq .sub_claim_prefix)"; then
      [[ "$prefix" == "$OIDC_SUBJECT_PREFIX" ]] \
        || die "GitHub reports OIDC subject prefix '$prefix', script has '$OIDC_SUBJECT_PREFIX'"
      ok "GitHub OIDC subject prefix matches"
    else
      printf '    warning: could not read the OIDC subject prefix from GitHub; using the configured one\n'
    fi
  fi
}

# ---------------------------------------------------------------------------
# 1. Resource providers (subscription scope, as you).
# ---------------------------------------------------------------------------

register_providers() {
  log "Resource providers"
  local ns state
  for ns in "${PROVIDERS[@]}"; do
    state="$(az provider show --namespace "$ns" --query registrationState -o tsv)"
    if [[ "$state" != "Registered" ]]; then
      az provider register --namespace "$ns" --wait --output none
      state="$(az provider show --namespace "$ns" --query registrationState -o tsv)"
    fi
    [[ "$state" == "Registered" ]] || die "$ns is $state"
    ok "$ns Registered"
  done
}

# ---------------------------------------------------------------------------
# 2. Resource group.
# ---------------------------------------------------------------------------

ensure_resource_group() {
  log "Resource group"
  az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --tags "${TAGS[@]}" --output none
  RG_ID="$(az group show --name "$RESOURCE_GROUP" --query id -o tsv)"
  ok "$RG_ID"
}

# ---------------------------------------------------------------------------
# 3. State storage.
# ---------------------------------------------------------------------------

ensure_state_storage() {
  log "State storage account"

  if ! az storage account show --resource-group "$RESOURCE_GROUP" --name "$STATE_ACCOUNT" --output none 2>/dev/null; then
    local available
    available="$(az storage account check-name --name "$STATE_ACCOUNT" --query nameAvailable -o tsv)"
    [[ "$available" == "true" ]] || die "storage account name $STATE_ACCOUNT is not available"
    az storage account create \
      --resource-group "$RESOURCE_GROUP" \
      --name "$STATE_ACCOUNT" \
      --location "$LOCATION" \
      --sku Standard_LRS \
      --kind StorageV2 \
      --access-tier Hot \
      --min-tls-version TLS1_2 \
      --https-only true \
      --allow-blob-public-access false \
      --allow-shared-key-access false \
      --default-to-oauth-authentication true \
      --allow-cross-tenant-replication false \
      --public-network-access Enabled \
      --tags "${TAGS[@]}" \
      --output none
    ok "created $STATE_ACCOUNT"
  fi

  # Applied on every run, so a setting someone loosened by hand is put back.
  # Public network access stays Enabled: GitHub-hosted runners reach the
  # account over the internet, and private endpoints are out of scope. Access
  # is by Entra ID only, because shared keys are disabled.
  az storage account update \
    --resource-group "$RESOURCE_GROUP" \
    --name "$STATE_ACCOUNT" \
    --min-tls-version TLS1_2 \
    --https-only true \
    --allow-blob-public-access false \
    --allow-shared-key-access false \
    --default-to-oauth-authentication true \
    --allow-cross-tenant-replication false \
    --tags "${TAGS[@]}" \
    --output none
  ok "TLS 1.2 minimum, HTTPS only, no public blob access, no shared keys"

  # Versioning keeps every prior state file. Blob and container soft delete
  # are a second net: a deleted state blob or container is recoverable for
  # seven days.
  az storage account blob-service-properties update \
    --resource-group "$RESOURCE_GROUP" \
    --account-name "$STATE_ACCOUNT" \
    --enable-versioning true \
    --enable-delete-retention true \
    --delete-retention-days 7 \
    --enable-container-delete-retention true \
    --container-delete-retention-days 7 \
    --output none
  ok "versioning on, blob and container soft delete 7 days"

  # Created through ARM (container-rm), not the data plane, so this works with
  # shared keys disabled and needs no data role for you.
  local exists
  exists="$(az storage container-rm exists --resource-group "$RESOURCE_GROUP" \
    --storage-account "$STATE_ACCOUNT" --name "$STATE_CONTAINER" --query exists -o tsv)"
  if [[ "$exists" != "true" ]]; then
    az storage container-rm create --resource-group "$RESOURCE_GROUP" \
      --storage-account "$STATE_ACCOUNT" --name "$STATE_CONTAINER" \
      --public-access off --output none
  fi
  ok "container $STATE_CONTAINER (private)"

  STATE_ACCOUNT_ID="$(az storage account show --resource-group "$RESOURCE_GROUP" --name "$STATE_ACCOUNT" --query id -o tsv)"
  STATE_CONTAINER_SCOPE="${STATE_ACCOUNT_ID}/blobServices/default/containers/${STATE_CONTAINER}"

  # CanNotDelete blocks deleting the account, by anyone, until the lock is
  # removed. Removing a lock needs Microsoft.Authorization/locks/delete, which
  # Contributor does not have, so the APPLY identity can never delete the
  # account that holds its own state. Only Owner or User Access Administrator
  # (you) can lift it.
  az lock create \
    --name "$STATE_LOCK_NAME" \
    --lock-type CanNotDelete \
    --resource-group "$RESOURCE_GROUP" \
    --resource "$STATE_ACCOUNT" \
    --resource-type Microsoft.Storage/storageAccounts \
    --notes "Holds Terraform state for portfolio-on-azure. Remove only during teardown (docs/teardown.md)." \
    --output none
  ok "CanNotDelete lock $STATE_LOCK_NAME"
}

# ---------------------------------------------------------------------------
# 4. CI identities: app registrations, service principals, federated
#    credentials. No secrets, no certificates.
# ---------------------------------------------------------------------------

# Echoes the appId of the single app registration with this display name,
# creating it if it does not exist.
ensure_app() {
  local name="$1" count app_id
  count="$(az ad app list --display-name "$name" --query 'length(@)' -o tsv)"
  if [[ "$count" == "0" ]]; then
    app_id="$(az ad app create --display-name "$name" --sign-in-audience AzureADMyOrg --query appId -o tsv)"
  elif [[ "$count" == "1" ]]; then
    app_id="$(az ad app list --display-name "$name" --query '[0].appId' -o tsv)"
  else
    die "$count app registrations are named $name; resolve by hand"
  fi
  printf '%s' "$app_id"
}

# Echoes the object ID of the service principal for an appId, creating it if
# needed. Role assignments are made to this object, not to the app.
ensure_sp() {
  local app_id="$1" sp_id
  if ! sp_id="$(az ad sp show --id "$app_id" --query id -o tsv 2>/dev/null)"; then
    sp_id="$(retry az ad sp create --id "$app_id" --query id -o tsv)"
  fi
  printf '%s' "$sp_id"
}

# The whole point of OIDC is that there is no long-lived credential to leak.
# If one exists, something outside this script added it: stop and say so
# rather than build on top of it.
assert_no_credentials() {
  local app_id="$1" name="$2" secrets certs
  secrets="$(az ad app show --id "$app_id" --query 'length(passwordCredentials)' -o tsv)"
  certs="$(az ad app show --id "$app_id" --query 'length(keyCredentials)' -o tsv)"
  [[ "$secrets" == "0" && "$certs" == "0" ]] \
    || die "$name has $secrets client secret(s) and $certs certificate(s); remove them before continuing"
  ok "$name: 0 client secrets, 0 certificates"
}

ensure_federated_credential() {
  local app_id="$1" name="$2" subject="$3" description="$4" current
  current="$(az ad app federated-credential list --id "$app_id" \
    --query "[?name=='${name}'].subject | [0]" -o tsv)"
  if [[ "$current" == "$subject" ]]; then
    ok "federated credential $name -> $subject"
    return
  fi
  cat >"$WORK_DIR/fic.json" <<JSON
{
  "name": "${name}",
  "issuer": "${OIDC_ISSUER}",
  "subject": "${subject}",
  "audiences": ["${OIDC_AUDIENCE}"],
  "description": "${description}"
}
JSON
  if [[ -z "$current" ]]; then
    az ad app federated-credential create --id "$app_id" --parameters "@$WORK_DIR/fic.json" --output none
  else
    az ad app federated-credential update --id "$app_id" --federated-credential-id "$name" \
      --parameters "@$WORK_DIR/fic.json" --output none
  fi
  ok "federated credential $name -> $subject"
}

# A credential nobody uses is an unused door. Report any this script did not
# make; it does not delete them, because it did not create them.
report_extra_credentials() {
  local app_id="$1" app_name="$2"; shift 2
  local expected=("$@") name known extras=0
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    known=0
    for e in "${expected[@]}"; do [[ "$name" == "$e" ]] && known=1; done
    if [[ "$known" == "0" ]]; then
      printf '    WARNING: %s has an unexpected federated credential: %s\n' "$app_name" "$name"
      extras=1
    fi
  done < <(az ad app federated-credential list --id "$app_id" --query '[].name' -o tsv)
  [[ "$extras" == "0" ]] && ok "$app_name: no federated credentials beyond the expected ones"
  return 0
}

ensure_ci_identities() {
  log "CI identity: PLAN ($PLAN_APP_NAME)"
  PLAN_APP_ID="$(ensure_app "$PLAN_APP_NAME")"
  PLAN_SP_ID="$(ensure_sp "$PLAN_APP_ID")"
  ok "appId $PLAN_APP_ID, service principal $PLAN_SP_ID"
  assert_no_credentials "$PLAN_APP_ID" "$PLAN_APP_NAME"
  # Pull requests: the fmt/validate/plan job. Fork PRs never receive an OIDC
  # token, so this subject is only presented by branches in this repository.
  ensure_federated_credential "$PLAN_APP_ID" "pull-request" \
    "${OIDC_SUBJECT_PREFIX}:pull_request" \
    "terraform plan on pull requests to ${GITHUB_REPO}"
  # Pushes to main: the job that saves the plan the APPLY job will run. It does
  # not reference an environment (it must not wait for approval, since the
  # approval is OF its output), so its subject is the branch ref.
  ensure_federated_credential "$PLAN_APP_ID" "main-branch" \
    "${OIDC_SUBJECT_PREFIX}:ref:refs/heads/main" \
    "terraform plan -out on pushes to main of ${GITHUB_REPO}"
  report_extra_credentials "$PLAN_APP_ID" "$PLAN_APP_NAME" pull-request main-branch

  log "CI identity: APPLY ($APPLY_APP_NAME)"
  APPLY_APP_ID="$(ensure_app "$APPLY_APP_NAME")"
  APPLY_SP_ID="$(ensure_sp "$APPLY_APP_ID")"
  ok "appId $APPLY_APP_ID, service principal $APPLY_SP_ID"
  assert_no_credentials "$APPLY_APP_ID" "$APPLY_APP_NAME"
  # Only the apply job references the azure-demo environment, which requires
  # approval and only accepts deployments from main. When a job references an
  # environment, GitHub puts the environment in the subject instead of the
  # branch, so no branch credential is needed or created here.
  ensure_federated_credential "$APPLY_APP_ID" "environment-${DEPLOY_ENVIRONMENT}" \
    "${OIDC_SUBJECT_PREFIX}:environment:${DEPLOY_ENVIRONMENT}" \
    "terraform apply of a saved plan, behind the ${DEPLOY_ENVIRONMENT} approval gate"
  report_extra_credentials "$APPLY_APP_ID" "$APPLY_APP_NAME" "environment-${DEPLOY_ENVIRONMENT}"
}

# ---------------------------------------------------------------------------
# 5. Custom role for the PLAN identity.
# ---------------------------------------------------------------------------

ensure_secret_reference_role() {
  log "Custom role: $SECRET_REF_ROLE_NAME"
  # azurerm refreshes a Container App or Job by calling listSecrets and fails
  # the whole plan if that is denied. Reader has only */read, and listSecrets
  # is an action, so a Reader-only plan breaks as soon as the apps exist.
  # These apps hold no secret values: every secret is a Key Vault reference,
  # so listSecrets returns the vault URL and the identity, not a value.
  # (Verified against the live apps in verification step 5.)
  local existing id_line=""
  existing="$(az role definition list --custom-role-only true --scope "$RG_ID" \
    --query "[?roleName=='${SECRET_REF_ROLE_NAME}'].name | [0]" -o tsv)"
  # An update must name the definition it replaces.
  [[ -n "$existing" ]] && id_line="\"Id\": \"${existing}\","
  cat >"$WORK_DIR/role.json" <<JSON
{
  ${id_line}
  "Name": "${SECRET_REF_ROLE_NAME}",
  "IsCustom": true,
  "Description": "Lets terraform plan refresh Container Apps and Jobs whose secrets are Key Vault references. Grants listSecrets only: no write, no delete.",
  "Actions": [
    "Microsoft.App/containerApps/listSecrets/action",
    "Microsoft.App/jobs/listSecrets/action"
  ],
  "NotActions": [],
  "DataActions": [],
  "NotDataActions": [],
  "AssignableScopes": ["${RG_ID}"]
}
JSON
  if [[ -z "$existing" ]]; then
    az role definition create --role-definition "@$WORK_DIR/role.json" --output none
  else
    az role definition update --role-definition "@$WORK_DIR/role.json" --output none
  fi
  SECRET_REF_ROLE_ID="$(retry az role definition list --custom-role-only true --scope "$RG_ID" \
    --query "[?roleName=='${SECRET_REF_ROLE_NAME}'].name | [0]" -o tsv)"
  [[ -n "$SECRET_REF_ROLE_ID" ]] || die "custom role did not appear"
  ok "role definition $SECRET_REF_ROLE_ID, assignable only at $RG_ID"
}

# ---------------------------------------------------------------------------
# 6. Role assignments.
# ---------------------------------------------------------------------------

# ensure_role <principal-object-id> <principal-type> <role-definition-guid> <scope> <description> [condition]
ensure_role() {
  local principal="$1" ptype="$2" role="$3" scope="$4" description="$5" condition="${6:-}"
  local existing_id existing_condition

  existing_id="$(az role assignment list --assignee "$principal" --scope "$scope" \
    --query "[?scope=='${scope}' && ends_with(roleDefinitionId, '${role}')].id | [0]" -o tsv)"

  if [[ -n "$existing_id" ]]; then
    existing_condition="$(az role assignment list --assignee "$principal" --scope "$scope" \
      --query "[?id=='${existing_id}'].condition | [0]" -o tsv)"
    if [[ "$(squash "$existing_condition")" == "$(squash "$condition")" ]]; then
      ok "$description"
      return
    fi
    # The condition is the security boundary; if it drifted, replace the
    # assignment rather than leave a looser one in place.
    printf '    condition differs from the expected one; replacing assignment\n'
    az role assignment delete --ids "$existing_id" --output none
  fi

  local args=(
    --assignee-object-id "$principal"
    --assignee-principal-type "$ptype"
    --role "$role"
    --scope "$scope"
    --description "$description"
    --output none
  )
  if [[ -n "$condition" ]]; then
    args+=(--condition "$condition" --condition-version 2.0)
  fi
  retry az role assignment create "${args[@]}"
  ok "$description"
}

ensure_role_assignments() {
  log "Role assignments: PLAN"
  ensure_role "$PLAN_SP_ID" ServicePrincipal "$ROLE_READER" "$RG_ID" \
    "PLAN: Reader on the resource group, to refresh state"
  ensure_role "$PLAN_SP_ID" ServicePrincipal "$SECRET_REF_ROLE_ID" "$RG_ID" \
    "PLAN: listSecrets on Container Apps and Jobs, which azurerm needs to refresh them"
  ensure_role "$PLAN_SP_ID" ServicePrincipal "$ROLE_BLOB_DATA_CONTRIBUTOR" "$STATE_CONTAINER_SCOPE" \
    "PLAN: write on the state container only, because taking the state lock is a write"

  log "Role assignments: APPLY"
  ensure_role "$APPLY_SP_ID" ServicePrincipal "$ROLE_CONTRIBUTOR" "$RG_ID" \
    "APPLY: Contributor on the resource group, to create and change resources"
  ensure_role "$APPLY_SP_ID" ServicePrincipal "$ROLE_BLOB_DATA_CONTRIBUTOR" "$STATE_CONTAINER_SCOPE" \
    "APPLY: read and write on the state container only"
  ensure_role "$APPLY_SP_ID" ServicePrincipal "$ROLE_RBAC_ADMIN" "$RG_ID" \
    "APPLY: may assign Key Vault Secrets User to service principals only" \
    "$RBAC_ADMIN_CONDITION"

  log "Role assignments: you"
  local me
  me="$(az ad signed-in-user show --query id -o tsv)"
  ensure_role "$me" User "$ROLE_BLOB_DATA_READER" "$STATE_CONTAINER_SCOPE" \
    "Operator: read-only on the state container, to audit state"
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

summary() {
  log "Done. Repository variables for ${GITHUB_REPO} (identifiers, not secrets):"
  printf '    AZURE_TENANT_ID=%s\n' "$TENANT_ID"
  printf '    AZURE_SUBSCRIPTION_ID=%s\n' "$SUBSCRIPTION_ID"
  printf '    AZURE_PLAN_CLIENT_ID=%s\n' "$PLAN_APP_ID"
  printf '    AZURE_APPLY_CLIENT_ID=%s\n' "$APPLY_APP_ID"
  printf '\n    bootstrap/github.sh sets these and creates the %s environment.\n' "$DEPLOY_ENVIRONMENT"
  printf '\n    After the shared-resources apply creates the Key Vault, grant yourself\n'
  printf '    Key Vault Secrets Officer on it (docs/secrets.md has the command).\n'
}

main() {
  preflight
  register_providers
  ensure_resource_group
  ensure_state_storage
  ensure_ci_identities
  ensure_secret_reference_role
  ensure_role_assignments
  summary
}

main "$@"
