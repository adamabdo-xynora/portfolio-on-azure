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
#   3. A ruleset on main: changes arrive only by pull request with the
#      `checks (no Azure)` and `plan (pull request)` checks green; no force
#      push, no deletion, and no bypass, including for the admin.

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

tmp_ruleset="$(mktemp)"
trap 'rm -f "$tmp_ruleset"' EXIT

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
# can_admins_bypass is false: GitHub's default lets a repository admin deploy
# past the required reviewer, which on a one-person repository would make the
# approval a convention rather than a control.
gh api --method PUT "repos/${REPO}/environments/${ENVIRONMENT}" --input - >/dev/null <<JSON
{
  "wait_timer": 0,
  "prevent_self_review": false,
  "can_admins_bypass": false,
  "reviewers": [{ "type": "User", "id": ${REVIEWER_ID} }],
  "deployment_branch_policy": { "protected_branches": false, "custom_branch_policies": true }
}
JSON
bypass="$(gh api "repos/${REPO}/environments/${ENVIRONMENT}" --jq .can_admins_bypass)"
[[ "$bypass" == "false" ]] || die "can_admins_bypass is '$bypass', expected false"
ok "required reviewer ${REVIEWER_LOGIN} (${REVIEWER_ID}); admins cannot bypass"

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

printf '==> Ruleset on main\n'
# Every change to main arrives through a pull request whose checks passed.
# Without this, a direct push to main would skip the PR plan and comment,
# and land straight in the plan-main/apply path (which is still gated by the
# azure-demo approval, but would have had no reviewed PR behind it).
#
#   required_approving_review_count is 0 on purpose: this repository has one
#   maintainer, and GitHub does not let an author approve their own pull
#   request, so any higher number would block every merge. A team would set
#   it to at least 1. The review that matters for infrastructure, approving
#   the saved plan, is enforced separately by the azure-demo environment.
#
#   The required checks are pinned to the GitHub Actions app (integration
#   15368), so a status reported by anything else cannot satisfy them.
#   strict: the PR branch must be up to date with main, so the plan that was
#   reviewed in the PR was made against the current main.
#
#   bypass_actors is empty: the rules apply to the repository admin too.
#   Force pushes (non_fast_forward) and deleting main are blocked.
readonly RULESET_NAME="main: pull request and green plan required"
readonly ACTIONS_APP_ID=15368
cat >"$tmp_ruleset" <<JSON
{
  "name": "${RULESET_NAME}",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": [],
  "conditions": { "ref_name": { "include": ["refs/heads/main"], "exclude": [] } },
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 0,
        "dismiss_stale_reviews_on_push": true,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": false
      }
    },
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": true,
        "do_not_enforce_on_create": false,
        "required_status_checks": [
          { "context": "checks (no Azure)", "integration_id": ${ACTIONS_APP_ID} },
          { "context": "plan (pull request)", "integration_id": ${ACTIONS_APP_ID} }
        ]
      }
    }
  ]
}
JSON
ruleset_id="$(gh api "repos/${REPO}/rulesets" --jq "[.[] | select(.name == \"${RULESET_NAME}\") | .id] | first // empty")"
if [[ -z "$ruleset_id" ]]; then
  ruleset_id="$(gh api --method POST "repos/${REPO}/rulesets" --input "$tmp_ruleset" --jq .id)"
else
  gh api --method PUT "repos/${REPO}/rulesets/${ruleset_id}" --input "$tmp_ruleset" >/dev/null
fi

# Read it back and check what GitHub actually stored.
summary="$(gh api "repos/${REPO}/rulesets/${ruleset_id}" --jq '[
  .enforcement,
  (.bypass_actors | length | tostring),
  ([.rules[].type] | sort | join(",")),
  (.rules[] | select(.type == "pull_request") | .parameters.required_approving_review_count | tostring),
  ([.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[] | "\(.context)@\(.integration_id)"] | sort | join(";"))
] | join("|")')"
expected="active|0|deletion,non_fast_forward,pull_request,required_status_checks|0|checks (no Azure)@${ACTIONS_APP_ID};plan (pull request)@${ACTIONS_APP_ID}"
[[ "$summary" == "$expected" ]] || die "ruleset as stored does not match: got '$summary', expected '$expected'"
ok "ruleset ${ruleset_id}: PR required (0 approvals), checks required, no force push, no deletion, no bypass"

printf '\nDone.\n'
