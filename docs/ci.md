# CI/CD

One workflow, [`.github/workflows/terraform.yml`](../.github/workflows/terraform.yml).

| Job | Runs on | Azure identity | `GITHUB_TOKEN` permissions | Does |
|---|---|---|---|---|
| `checks` | every PR, push to main and manual run | none | `contents: read`, `attestations: read` | shellcheck the scripts, verify the provenance of every pinned image (`scripts/verify_images.sh`), test the plan-secrets guard, `terraform fmt -check`, `terraform validate` |
| `plan-pr` | pull requests | PLAN | `contents: read`, `id-token: write` | `terraform plan`, plan-secrets guard, hands the plan text to `comment` |
| `comment` | pull requests | none | `pull-requests: write` | posts or updates one plan comment on the PR |
| `plan-main` | push to main, or a manual run (`workflow_dispatch`) | PLAN | `contents: read`, `id-token: write` | `terraform plan -out`, plan-secrets guard, SHA-256 of the plan file, uploads it |
| `apply` | push to main only, and only if the plan has changes; never on a manual run | APPLY, in environment `azure-demo` | `contents: read`, `id-token: write` | waits for approval, checks the plan file's SHA-256, applies that file |

The workflow grants nothing at the top level (`permissions: {}`). Each job
asks only for what it uses. The job that can write to the pull request has no
Azure token, and the jobs with Azure tokens cannot write to the pull request.

**Manual drift check.** `gh workflow run terraform.yml --ref main` runs
`checks` and `plan-main` only, as the read-only PLAN identity. It is used
after each apply to confirm a fresh plan shows no changes. `apply` is
conditioned on a push, so a manual run cannot apply anything.

## What gets applied is what was approved

1. `plan-main` saves the binary plan, prints its SHA-256 in the job summary,
   and passes the hash to `apply` as a job output.
2. `apply` is held by the `azure-demo` environment until the required
   reviewer approves. Admin bypass is off. The reviewer reads the plan in
   `plan-main`'s summary.
3. After approval, `apply` downloads the plan file and refuses to continue
   unless its SHA-256 equals the one `plan-main` produced. Then it runs
   `terraform apply tfplan`, the saved plan and nothing else. There is no
   `terraform plan` in the apply job and no `-auto-approve` anywhere.
4. If anything changed state between plan and apply, Terraform rejects the
   saved plan as stale. The fix is a new run, which means a new approval.

## Identities and identifiers

Azure login is keyless: GitHub issues the job an OIDC token, and Entra ID
exchanges it for an Azure token only if the token's subject matches a
federated credential (see [identities.md](identities.md)). The workflow needs
four values, stored as **repository variables, not secrets**:

| Variable | What it is |
|---|---|
| `AZURE_TENANT_ID` | the Entra tenant |
| `AZURE_SUBSCRIPTION_ID` | the subscription |
| `AZURE_PLAN_CLIENT_ID` | the PLAN app registration's client ID |
| `AZURE_APPLY_CLIENT_ID` | the APPLY app registration's client ID |

They are identifiers. Knowing all four lets nobody log in, because there is
no secret to pair them with. Login needs a GitHub-signed token for this
repository with the right subject. The repository has no Actions secrets,
no environment secrets, and no Dependabot secrets.

Pull requests from forks get no OIDC token, so their plan job fails at login
by design. Only branches in this repository can run a plan against Azure.

## Image provenance, before any plan or apply

`images.json` pins each container image by the digest of its multi-arch
index, never by tag. A tag can be moved to different bytes; a digest
cannot. `scripts/verify_images.sh` runs in `checks`, which every plan and
apply depends on. For each image it requires a SLSA provenance attestation
whose signing certificate names exactly the source repository's
`publish.yml` workflow at the release tag (`--cert-identity`), with that tag
as the source ref, built on a GitHub-hosted runner. It then verifies the
same image against a wrong signer identity and fails unless that is
rejected, so a verifier that accepts anything cannot pass silently. Before
first use it was also run against an unattested digest (the webhook-guard
amd64 child manifest), which it rejected.

## Public artifacts and logs

This repository is public, so its Actions logs and artifacts are readable by
anyone. What is in them:

- **The plan text** (job logs, the PR comment, the job summary). Resource
  names, IDs, settings, tags and principal IDs. No secret values: Terraform
  prints sensitive attributes as `(sensitive value)`, and there are none to
  print anyway (below).
- **The binary plan file** (`tfplan` artifact, kept 1 day). A saved plan
  embeds a full copy of the state it was planned against, sensitive
  attributes included, in plain text. That is why the next check exists.

**The plan-secrets guard** ([`scripts/plan_secrets_guard.py`](../scripts/plan_secrets_guard.py))
runs on every plan, before anything is uploaded. It reads
`terraform show -json` and fails the job if any attribute Terraform marks
sensitive holds a value, in prior state, planned values, changes, outputs or
variables. It reports where, never what. Its tests run in `checks` on every
run. They include a real Terraform plan with a sensitive canary: the guard
must fail on it, and must not print it.

The guard is the backstop, not the design. The design keeps sensitive
material out of state in the first place:

- No secret values in Terraform: no variables, no `.tfvars`, no
  `azurerm_key_vault_secret`. Values are set by hand (see
  [secrets.md](secrets.md)).
- `azapi` for the resources whose azurerm refresh would read secret
  material: the Log Analytics workspace (shared keys) and the Container App
  and Job (`listSecrets`).

Artifacts are kept for one day, the shortest retention GitHub allows. The
apply runs within minutes of the plan, so nothing needs them longer.

## Changes to main: the ruleset

`main` is protected by a repository ruleset, created and checked by
`bootstrap/github.sh`, so it is reproducible rather than a one-off setting:

| Rule | Setting |
|---|---|
| Pull request required | yes, with **0** required approvals (see below) |
| Required status checks | `checks (no Azure)` and `plan (pull request)`, both pinned to the GitHub Actions app (integration 15368); the branch must be up to date with `main` |
| Force pushes | blocked |
| Deleting `main` | blocked |
| Bypass actors | none: the rules apply to the repository admin too (GitHub reports `current_user_can_bypass: never`) |

**Why 0 required approvals.** This repository has one maintainer, and GitHub
does not let the author of a pull request approve it, so any higher number
would block every merge. A team would set it to at least 1. The review that
gates infrastructure, approving the saved plan before it is applied, is
enforced separately by the `azure-demo` environment, which does have a
required reviewer and no admin bypass.

Verified on 2026-10-04 by pushing a commit directly to `main`. GitHub
rejected it with `GH013: Repository rule violations`: *"Changes must be made
through a pull request"* and *"2 of 2 required status checks are expected."*
