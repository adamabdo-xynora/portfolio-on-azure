#!/usr/bin/env bash
#
# bootstrap/github.sh: the GitHub half of bootstrap.
#
# Run after bootstrap.sh, by someone logged in to both `az` and `gh` with
# admin rights on the repository. Idempotent.
#
#   1. Repository variables (not secrets) with the identifiers the workflows
#      pass to azure/login. They are identifiers: knowing them lets nobody
#      log in, because login needs a GitHub-issued OIDC token whose subject
#      matches a federated credential. This repository has no secrets at all.
#   2. The azure-demo environment: a required reviewer, and deployments only
#      from main. The APPLY identity trusts only tokens issued to jobs in this
#      environment, so the approval gate is enforced by Entra ID as well as
#      by GitHub: a job outside the environment cannot get an APPLY token.

set -euo pipefail

readonly REPO="adamabdo-xynora/portfolio-on-azure"
readonly ENVIRONMENT="azure-demo"
readonly REVIEWER_LOGIN="adamabdo-xynora"

readonly TENANT_ID="4f2b53e0-95e0-473a-aeb3-1b4dd425d486"
readonly SUBSCRIPTION_ID="8e03f5b9-58e3-4036-9ded-0893a09fe1e1"
readonly PLAN_APP_NAME="github-portfolio-on-azure-plan"
readonly APPLY_APP_NAME="github-portfolio-on-azure-apply"

ok() { printf '    ok: %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

app_id_for() {
  local name="$1" count
  count="$(az ad app list --display-name "$name" --query 'length(@)' -o tsv)"
  [[ "$count" == "1" ]] || die "expected one app registration named $name, found $count (run bootstrap.sh first)"
  az ad app list --display-name "$name" --query '[0].appId' -o tsv
}

printf '==> Repository variables\n'
PLAN_CLIENT_ID="$(app_id_for "$PLAN_APP_NAME")"
APPLY_CLIENT_ID="$(app_id_for "$APPLY_APP_NAME")"
gh variable set AZURE_TENANT_ID --repo "$REPO" --body "$TENANT_ID"
gh variable set AZURE_SUBSCRIPTION_ID --repo "$REPO" --body "$SUBSCRIPTION_ID"
gh variable set AZURE_PLAN_CLIENT_ID --repo "$REPO" --body "$PLAN_CLIENT_ID"
gh variable set AZURE_APPLY_CLIENT_ID --repo "$REPO" --body "$APPLY_CLIENT_ID"
ok "AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID, AZURE_PLAN_CLIENT_ID, AZURE_APPLY_CLIENT_ID"

secret_count="$(gh api "repos/${REPO}/actions/secrets" --jq .total_count)"
[[ "$secret_count" == "0" ]] || die "the repository has $secret_count Actions secret(s); this project uses none"
ok "repository has 0 Actions secrets"

printf '==> Environment %s\n' "$ENVIRONMENT"
REVIEWER_ID="$(gh api "users/${REVIEWER_LOGIN}" --jq .id)"
# prevent_self_review stays false: this is a one-person project, and the
# person who merges is the only possible reviewer. Recorded as a trade-off in
# the README; a team would turn it on.
gh api --method PUT "repos/${REPO}/environments/${ENVIRONMENT}" --input - >/dev/null <<JSON
{
  "wait_timer": 0,
  "prevent_self_review": false,
  "reviewers": [{ "type": "User", "id": ${REVIEWER_ID} }],
  "deployment_branch_policy": { "protected_branches": false, "custom_branch_policies": true }
}
JSON
ok "required reviewer ${REVIEWER_LOGIN} (${REVIEWER_ID})"

policies="$(gh api "repos/${REPO}/environments/${ENVIRONMENT}/deployment-branch-policies" \
  --jq '[.branch_policies[] | "\(.type):\(.name)"] | join(",")')"
if [[ ",${policies}," != *",branch:main,"* ]]; then
  gh api --method POST "repos/${REPO}/environments/${ENVIRONMENT}/deployment-branch-policies" \
    -f name=main -f type=branch >/dev/null
fi
policies="$(gh api "repos/${REPO}/environments/${ENVIRONMENT}/deployment-branch-policies" \
  --jq '[.branch_policies[] | "\(.type):\(.name)"] | join(",")')"
[[ "$policies" == "branch:main" ]] || die "unexpected deployment branch policies: $policies"
ok "deployments only from main"

printf '\nDone.\n'
