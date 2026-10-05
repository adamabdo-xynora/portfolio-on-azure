# Identities and roles

Every identity in this project, what it may do, where, and why. Nothing is
assigned at subscription scope, and `bootstrap.sh` aborts if any role
assignment is ever aimed above the resource group. Its only
subscription-level writes are registering resource providers and creating
the resource group itself. A human makes both, once, and neither grants
anything to any identity.

Scopes below:

- **RG** is `/subscriptions/8e03f5b9-58e3-4036-9ded-0893a09fe1e1/resourceGroups/rg-portfolio-on-azure`.
- **state container** is `…/storageAccounts/stportfolioazuretf/blobServices/default/containers/tfstate`.

## The two CI identities

CI uses two Entra app registrations. They exist for different jobs, and
neither has a client secret or a certificate. GitHub Actions logs in to Azure
with OpenID Connect: GitHub signs a short-lived token for the job, and
Entra ID exchanges it for an Azure token. The exchange only happens if the
GitHub token's `subject` exactly matches one of the app's federated
credentials, so nothing stored in GitHub or in this repository can be used
to log in.

### Subjects, and why they look unusual

This repository's OIDC tokens use GitHub's *immutable* subject format. The
owner and repository carry their numeric IDs:

```
repo:adamabdo-xynora@276160212/portfolio-on-azure@1404957986:<context>
```

The prefix comes from the repository's settings
(`gh api repos/adamabdo-xynora/portfolio-on-azure/actions/oidc/customization/sub`).
Because of the IDs, a repository deleted and re-created under the same name
cannot present these subjects, since it would get a new ID. The classic form
(`repo:adamabdo-xynora/portfolio-on-azure:<context>`) would never match a token
from this repository.

### PLAN: `github-portfolio-on-azure-plan`

| Role | Scope | Why |
|---|---|---|
| Reader | RG | `terraform plan` refreshes every resource. Reading is all a plan needs. |
| Storage Blob Data Contributor | state container | Terraform takes a lease on the state blob before planning, so concurrent runs cannot interleave. Taking a lease is a write. This identity never writes the state itself, because it never applies. |

Nothing else. In particular, the PLAN identity has no `listSecrets`
permission on Container Apps or Jobs. That is why those two resources are
managed with `azapi_resource`, whose refresh is a plain GET, rather than
azurerm, whose refresh calls `listSecrets`. See "Corrections" below.

What Reader does allow, stated plainly: it can query the Log Analytics
workspace (`workspaces/query/read` falls under `*/read`), so this identity
can read the apps' logs and the Key Vault audit events. Neither app logs
secret values by design, and audit events record who read which secret,
not its value.

Federated credentials, each used by exactly one job:

| Name | Subject context | Used by |
|---|---|---|
| `pull-request` | `:pull_request` | the PR job: fmt, validate, plan, plan comment |
| `main-branch` | `:ref:refs/heads/main` | the job on merge to main that saves the plan file |

**Why a main-branch credential exists.** When a job references a GitHub
environment, GitHub puts `environment:<name>` in the subject instead of the
branch. The apply job references `azure-demo`, so the APPLY identity needs no
branch credential. The plan job on main deliberately references *no*
environment, because the reviewer's approval is approval *of its output*. Its
subject is therefore the branch ref. Without this credential the plan on main
could not log in.

Pull requests from forks never receive an OIDC token, so `pull_request`
subjects only come from branches in this repository.

### APPLY: `github-portfolio-on-azure-apply`

| Role | Scope | Why |
|---|---|---|
| Contributor | RG | Creates and changes the resources Terraform manages. Contributor cannot manage role assignments or locks, which is why the two rows below are separate, and why this identity cannot remove the lock on the state account. |
| Storage Blob Data Contributor | state container | Reads and writes state, and takes the lock. |
| Role Based Access Control Administrator, **with a condition** | RG | Lets Terraform grant the managed identities read access to Key Vault secrets, and nothing else. See below. |

Federated credential:

| Name | Subject context | Used by |
|---|---|---|
| `environment-azure-demo` | `:environment:azure-demo` | the apply job only |

The `azure-demo` environment requires approval and accepts deployments only
from `main`. Because the credential is bound to the environment, the gate is
enforced twice: GitHub will not start the job without approval, and Entra ID
will not issue an APPLY token to any job outside that environment.

#### The RBAC Administrator condition

```
(
  (!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'}))
  OR
  (
    @Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {4633458b-17de-408a-b874-0445c86b69e6}
    AND
    @Request[Microsoft.Authorization/roleAssignments:PrincipalType] ForAnyOfAnyValues:StringEqualsIgnoreCase {'ServicePrincipal'}
  )
)
AND
(
  (!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'}))
  OR
  (
    @Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {4633458b-17de-408a-b874-0445c86b69e6}
    AND
    @Resource[Microsoft.Authorization/roleAssignments:PrincipalType] ForAnyOfAnyValues:StringEqualsIgnoreCase {'ServicePrincipal'}
  )
)
```

`4633458b-…` is the built-in **Key Vault Secrets User** role. The APPLY
identity may create an assignment only of that role, and only to a service
principal (managed identities are service principals). It may delete an
assignment only if it is that role on a service principal. So:

- it cannot grant itself, or anyone, Owner, Contributor or RBAC Administrator;
- it cannot grant anything to a user or a group;
- `terraform destroy` can still remove the assignments it created.

The Terraform resources set `principal_type = "ServicePrincipal"` explicitly.
Without it the request carries no principal type, and the condition denies it.

What the condition does not stop: the APPLY identity granting Key Vault
Secrets User to *some other* service principal in the tenant. The blast radius
is read access to secrets in this one resource group's vault. Narrowing it
further means constraining `PrincipalId`, which would hard-code managed
identity IDs that do not exist until Terraform creates them.

#### What APPLY can reach indirectly

CI never holds Key Vault Secrets Officer, but that is not the whole story.
APPLY holds Contributor on the RG, which includes
`Microsoft.App/containerApps/listSecrets/action`,
`Microsoft.App/jobs/listSecrets/action` and `Microsoft.App/jobs/start/action`.
Microsoft documents that starting a job with an override template can read
that job's secrets. More basically, any identity that can deploy an app can
deploy code that prints its environment. Removing those actions from APPLY
would not change that. The control on APPLY is the one GitHub and Entra ID
both enforce: it runs only a saved plan that a reviewer approved, from
`main`, in the `azure-demo` environment.

## You (the operator)

| Role | Scope | Granted by | Why |
|---|---|---|---|
| Owner | subscription | the free account | You created the subscription. Bootstrap and teardown run as you. |
| Storage Blob Data Reader | state container | `bootstrap.sh` | Read-only access to state, to audit it, for example to search it for secret values. You cannot write state; only CI does. |
| Key Vault Secrets Officer | each vault: `kv-poa-webhook-guard`, `kv-poa-rag-receipts` | one command per vault, after the shared-resources apply (`docs/secrets.md`) | To set secret values by hand. No CI identity holds this role or any Key Vault data role, so no pipeline can write a secret or read one directly. APPLY's indirect reach is described above. |

## The managed identities

User-assigned, one per workload, created by Terraform
(`terraform/identities.tf`). Each workload also has **its own Key Vault**
(`terraform/keyvault.tf`), and each identity can read **only its own
vault**.

| Identity | Used by | Role | Scope | Secrets in that vault |
|---|---|---|---|---|
| `id-webhook-guard` | the webhook-guard Container App | Key Vault Secrets User | the vault `kv-poa-webhook-guard` | `webhook-secret` |
| `id-rag-receipts` | the rag-receipts Container Apps Job | Key Vault Secrets User | the vault `kv-poa-rag-receipts` | `voyage-api-key`, plus `anthropic-api-key` only if a full eval run is approved |

**Why a vault per workload.** It is Microsoft's recommendation (see
"Change (2026-10-05)" below), and it means neither workload can read the
other's secrets: the webhook receiver cannot read the Voyage or Anthropic
keys, and the eval job cannot read the webhook signing secret. Grants are
at vault scope, so they are created with the vaults, before any secret is
set or any app references one. Nothing has to wait on role-assignment
propagation when an app first starts.

Key Vault Secrets User can read secret values and nothing else. It cannot
write or delete secrets, or change the vault. It is also the only role the
APPLY identity is allowed to assign (see the RBAC Administrator condition
above). Each assignment is created with
`principal_type = "ServicePrincipal"`, which that condition requires.

## Decisions and corrections

### Correction (2026-10-04): what `listSecrets` returns

An earlier revision of this project (the first commit on PR #1) gave the
PLAN identity a custom role, "Container Apps Secret Reference Reader",
holding `Microsoft.App/containerApps/listSecrets/action` and
`Microsoft.App/jobs/listSecrets/action`. It justified the role by saying
that for a secret that is a Key Vault reference, `listSecrets` returns
only the vault URL and the identity, not the value. **That claim was wrong.**
It was written from memory, not checked against Microsoft's documentation.
The role was removed before anything was deployed.

What the evidence shows:

- Microsoft's Container Apps documentation,
  [Manage secrets](https://learn.microsoft.com/en-us/azure/container-apps/manage-secrets)
  (updated 2026-09-11), says: *"Azure Container Apps exposes separate
  `listSecrets` operations for container apps, jobs, and Dapr components.
  These operations return secret values in plain text. Grant these
  permissions only to identities that need to read secret values."* Neither
  that page nor the
  [List Secrets REST reference](https://learn.microsoft.com/en-us/rest/api/resource-manager/containerapps/container-apps/list-secrets)
  excludes Key Vault references. The response schema has `value` alongside
  `keyVaultUrl` and `identity`.
- Microsoft's REST specification for API version 2026-07-01
  (`specification/app/resource-manager/Microsoft.App/ContainerApps/stable/2026-07-01/openapi.json`)
  marks `value` in the `listSecrets` response as `readOnly: true,
  x-ms-secret: true`. Autorest defines `x-ms-secret` this way: *"Secrets
  should never expose on a GET. If a secret does need to be returned after
  the fact, a POST api can be used."* `listSecrets` is that POST.
- The azurerm provider (5.8.0) does not write the value to state for a
  Key Vault reference: `FlattenContainerAppSecrets` and
  `FlattenContainerAppJobSecrets` keep `value` only when `KeyVaultURL` is
  nil. But the identity making the call still receives the response, and
  the PLAN identity runs on pull-request code. Anyone able to push a branch
  could add a step that calls `listSecrets` with its token.

So the permission could expose secret values, and the PLAN identity must not
hold it. The replacement:

- PLAN holds **Reader** only, plus its lease on the state container.
- The Container App and the Container Apps Job are managed with
  `azapi_resource`. Its refresh (azapi 2.13.0, `Read()` in
  `internal/services/azapi_resource.go`) makes one call, `client.Get`. In
  the GET/PUT body schema, `Secret.value` is `x-ms-secret: true` with
  `x-ms-mutability: ["update", "create"]`, with no `read`, so a GET never
  returns it.
- The Log Analytics workspace is also managed with azapi, for the related
  reason that azurerm's refresh copies the workspace's shared keys into state.

The rule that follows: where azurerm's refresh would touch secret material,
the resource is managed with azapi. Because azapi resources can show a
perpetual diff when the body read back differs from the body sent, each
first apply is followed by a fresh plan that must show zero changes
(`docs/verification.md`).

### Change (2026-10-05): one Key Vault per workload

Before anything was applied, the shared-resources pull request (#4) went
through two designs, both replaced:

1. **One vault, vault-scope grants.** Each identity could read every
   secret in the vault: the webhook receiver could read the Voyage key, and
   the eval job the webhook signing secret.
2. **One vault, per-secret grants.** This limited each identity to its own
   secrets. Its grants needed the secrets to exist first, so they would have
   been created in the same apply as the apps, where an app can start before
   a new role assignment takes effect.

Both were replaced by a vault per workload, because that is what Microsoft
recommends. Its Key Vault RBAC guide,
[Grant permission to applications to access an Azure key vault using Azure RBAC](https://learn.microsoft.com/en-us/azure/key-vault/general/rbac-guide)
(updated 2026-08-21), section *Best Practices for individual keys,
secrets, and certificates role assignments*, says:

> Our recommendation is to use a vault per application per environment
> (Development, Pre-Production, and Production) with roles assigned at the
> key vault scope.
>
> Assigning roles on individual keys, secrets and certificates is not
> recommended.

The listed exceptions (secrets that individual users must read, and
secrets shared between applications) do not apply here.

The result: two vaults, `kv-poa-webhook-guard` and `kv-poa-rag-receipts`,
each Standard, RBAC, 7-day soft delete, purge protection off, each with
its own AuditEvent diagnostic setting. Each workload's identity is Key
Vault Secrets User on its own vault only. Access is the same as with
per-secret grants (each identity reads only its own secrets), and it now
follows Microsoft's guidance. The grants also exist before any secret or
app does. Key Vault has no per-vault charge, so the second vault costs
nothing beyond its operations.

### Correction (2026-10-05): the Container Apps environment type

The shared-resources pull request (#4) declared the Container Apps
environment with no `workload_profile` block, and its comments, this
document and the README cost table said that this creates the legacy
**Consumption-only** environment type. They quoted Microsoft's statement
about that type: *"There's no cost associated with the Container Apps
environment."* **That claim was wrong.** It rested on how the type used to
be selected, not on what Azure creates today.

What the evidence shows:

- The first fresh plan after the apply (run as the operator, read-only)
  wanted to change the environment in place, removing a `workload_profile`
  named `Consumption` that the configuration never declared.
- Reading the environment from Azure (Microsoft.App API version 2026-07-01)
  shows `workloadProfiles: [{ name: "Consumption", workloadProfileType:
  "Consumption" }]`, with no Dedicated profile, no private endpoint
  connections, no VNet configuration, and no maintenance configurations.
- azurerm 5.8.0 creates environments with API version 2025-07-01
  (`container_app_environment_resource.go`) and sends no workload profiles
  when none are declared. Azure created a workload-profiles environment
  with the default Consumption profile. Microsoft's
  [environments page](https://learn.microsoft.com/en-us/azure/container-apps/environment)
  lists workload profiles as the default type and Consumption-only as legacy.

The fix declares the Consumption profile explicitly, so the configuration
matches what exists and a fresh plan is clean. The cost conclusion is
unchanged, but it now rests on the statement that applies to this type,
from Microsoft's
[Container Apps billing](https://learn.microsoft.com/en-us/azure/container-apps/billing)
documentation: *"You aren't billed any plan management charges unless you
use a Dedicated workload profile in your environment."* Private endpoints
and planned maintenance carry the same charge, and this environment has
neither. Whether the "Environment Management Hour" meter stays at zero will
be checked against actual usage data.

The same pull request removes the `deploying_identity_object_id` output.
Its value depends on who runs the plan, so a plan run by anyone but the
PLAN identity always showed a change. That made a local zero-change check
impossible.

### Trade-offs

- **Key Vault purge protection is off** on both vaults, with 7-day
  soft-delete retention, so teardown can purge them the same day. A production deployment
  would turn purge protection on: then no one, including an attacker with
  full rights, can permanently delete a deleted vault before its retention
  ends, so it always stays recoverable.
- **The Log Analytics workspace has a 0.1 GB/day cap,** to stay inside the
  5 GB/month free grant even if the cap is hit every day. Once the cap is
  reached, audit events stop until the daily reset. A production audit
  workspace would not be capped this way.
- **The state account allows public network access.** GitHub-hosted
  runners reach it over the internet. Access is Entra ID only, with shared
  keys off. A production deployment would use a private endpoint with
  self-hosted runners instead.
- **The `azure-demo` environment does not prevent self-review.** This is a
  one-person project, and the person who merges is the only possible
  reviewer. A team would turn `prevent_self_review` on. Admin bypass *is*
  off (`can_admins_bypass: false`), so even the repository admin cannot
  deploy without approving.
