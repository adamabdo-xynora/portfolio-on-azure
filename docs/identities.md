# Identities and roles

Every identity in this project, what it may do, where, and why. Nothing is
assigned at subscription scope. The only subscription-level actions in the
whole project (registering resource providers and creating one custom role
definition) are done once by a human in `bootstrap/bootstrap.sh`.

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
| Container Apps Secret Reference Reader *(custom)* | RG | Two actions: `Microsoft.App/containerApps/listSecrets/action` and `Microsoft.App/jobs/listSecrets/action`. The azurerm provider (5.8.0) refreshes a Container App or Job by calling `listSecrets`, and fails the whole plan if that call is denied. Reader holds only `*/read`, and `listSecrets` is an action, not a read. These apps hold no secret values (every secret is a Key Vault reference), so the call returns a vault URL and an identity. The role definition is assignable only inside the RG. |
| Storage Blob Data Contributor | state container | Terraform takes a lease on the state blob before planning, so concurrent runs cannot interleave. Taking a lease is a write. This identity never writes the state itself, because it never applies. |

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

## You (the operator)

| Role | Scope | Granted by | Why |
|---|---|---|---|
| Owner | subscription | the free account | You created the subscription. Bootstrap and teardown run as you. |
| Storage Blob Data Reader | state container | `bootstrap.sh` | Read-only access to state, to audit it, for example to search it for secret values. You cannot write state; only CI does. |
| Key Vault Secrets Officer | the Key Vault | one command, after the shared-resources apply (`docs/secrets.md`) | To set secret values by hand. CI never holds this role, so no pipeline can read or write a secret value. |

## The managed identities

Added with the shared resources (PR 3) and documented here when they exist.
