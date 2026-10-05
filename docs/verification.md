# Verification

What has to be shown, with evidence, before the README may claim it. Each
item gets a result line (date, command, outcome, link) when it is run.
Anything not run stays marked **not yet verified**.

## Standing rules

- **A first apply is not done until a fresh plan shows zero changes.** After
  the first apply of PR 4 (webhook-guard Container App) and PR 5
  (rag-receipts job), run a new `terraform plan` against the applied state.
  It must report `No changes. Your infrastructure matches the configuration.`
  Both resources are `azapi_resource`, and azapi can produce a perpetual
  diff when the body Azure returns differs from the body that was sent
  (defaults filled in, casing, property order in lists). A plan that always
  shows changes trains reviewers to approve without reading, which defeats
  the approval gate. If the fresh plan is not clean, fix the configuration
  (explicit defaults, `ignore_missing_property`, `ignore_casing`, or a
  narrowly scoped `lifecycle.ignore_changes` with a written reason) and
  re-apply before moving on. The same rule applies to PR 3's azapi workspace.
- **Anything changed by hand for a test is restored**, and a plan afterwards
  shows zero changes.
- **Exit codes are checked directly**, never through a pipe.
- **"The job executed" and "the gate verdict" are reported separately** for
  every rag-receipts run: execution status from Container Apps, gate output
  and exit code from the job's logs.

## Checks

| # | Claim | Evidence required | Result |
|---|---|---|---|
| 1 | OIDC works with no secrets | A CI run where `azure/login` succeeded via a federated credential; both app registrations show 0 client secrets and 0 certificates | not yet verified |
| 2 | Plan on PR, apply on merge, same plan | A PR with the plan comment; an apply run that waited for approval; the saved plan's SHA-256 matches between the plan job and the apply job | not yet verified |
| 3 | PLAN identity cannot write | Its full role list (Reader on RG, Blob Data Contributor on the state container, nothing else), and a write attempt denied | not yet verified |
| 4 | webhook-guard is live | `GET /healthz` → 200; unsigned `POST /webhook` → 401; replica count back to 0 after idling; running revision's image is the pinned digest | not yet verified |
| 4a | PR 4 plan is clean | Fresh plan after first apply: zero changes | not yet verified |
| 5 | Secret path is real | App secret is a Key Vault reference (redacted config); Key Vault `AuditEvent` shows the managed identity's `SecretGet`. Optional, with approval: remove the role, show a new revision failing, restore, plan shows zero changes | not yet verified |
| 6 | rag-receipts job runs | Manual start with `--calibrate`; execution status and gate output shown separately; log lines in Log Analytics with the KQL used | not yet verified |
| 6a | PR 5 plan is clean | Fresh plan after first apply: zero changes | not yet verified |
| 7 | Least privilege | Every role assignment for both CI identities, both managed identities and the operator, with scopes and the RBAC Administrator condition; nothing at subscription scope | not yet verified |
| 8 | State is safe | Remote state; locking; versioning on; public access off; shared-key access off; lock present; a search of state for the secret names finds no values | not yet verified |
| 9 | Cost | Cost Management spend for the RG; the budget and its thresholds; no "Environment Management Hour" meter in the usage | not yet verified |
