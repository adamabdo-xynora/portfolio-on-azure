# Teardown

Removes everything this project created, in an order that never leaves a
dangling permission or a billable resource. Run it as yourself (Owner on the
subscription), from the repository root, with `az login` and `gh auth login`
done. Nothing here uses `-auto-approve`: every destructive step either shows
you what it will do first, or asks.

**Run it before the free credit expires.** The date is recorded in the README
once Azure exposes it; Cost Management data for a new account takes up to 48
hours to appear.

```bash
RG=rg-portfolio-on-azure
SA=stportfolioazuretf
KV=kv-portfolio-on-azure
LOCATION=canadacentral
SCOPE_RG=$(az group show -n "$RG" --query id -o tsv)
ME=$(az ad signed-in-user show --query id -o tsv)
```

## 1. Revoke your own Key Vault role, while the vault still exists

```bash
az role assignment delete --assignee "$ME" --role "Key Vault Secrets Officer" \
  --scope "$(az keyvault show -n "$KV" -g "$RG" --query id -o tsv)"
```

## 2. Destroy everything Terraform manages

`terraform destroy` writes state, and your bootstrap role on the state
container is read-only. Grant yourself write for the duration, and remove it
in step 4 along with the container.

```bash
az role assignment create --assignee-object-id "$ME" --assignee-principal-type User \
  --role "Storage Blob Data Contributor" \
  --scope "$(az storage account show -n "$SA" -g "$RG" --query id -o tsv)/blobServices/default/containers/tfstate"

cd terraform
terraform init
terraform plan -destroy -out=destroy.tfplan   # read the summary: every line should be a destroy
terraform apply destroy.tfplan                # applies exactly the plan you just read
rm -f destroy.tfplan
cd ..
```

This removes the Container App, the job, the Container Apps environment, the
Key Vault (into soft delete), the Log Analytics workspace (permanently, see
`delete_query_parameters` in the Terraform), the managed identities and their
role assignments, the diagnostic settings and the budget. It does not touch
the resource group or the state account: Terraform reads the first as a data
source and never knew about the second.

## 3. Remove the CI identities' role assignments, then the identities

Role assignments are removed explicitly, before the principals are deleted,
so none is left behind as an orphaned "Unknown" assignment.

```bash
for app in github-portfolio-on-azure-plan github-portfolio-on-azure-apply; do
  app_id=$(az ad app list --display-name "$app" --query '[0].appId' -o tsv)
  sp_id=$(az ad sp show --id "$app_id" --query id -o tsv)
  for id in $(az role assignment list --assignee "$sp_id" --all --query '[].id' -o tsv); do
    az role assignment delete --ids "$id"
  done
  obj_id=$(az ad app show --id "$app_id" --query id -o tsv)
  az ad app delete --id "$app_id"     # also deletes its service principal and federated credentials
  # Deleted apps sit in the Entra recycle bin for 30 days; empty it.
  az rest --method DELETE --url "https://graph.microsoft.com/v1.0/directory/deletedItems/$obj_id"
done

az role definition delete --name "Container Apps Secret Reference Reader (portfolio-on-azure)" \
  --scope "$SCOPE_RG"
```

## 4. Lift the lock, then delete the resource group

The CanNotDelete lock is what stops anyone deleting the state account. Only
an Owner (you) can lift it. Lifting it before this step would be pointless:
steps 1–3 do not touch the account.

```bash
# Your roles on the state container (bootstrap's reader role, step 2's writer role).
for id in $(az role assignment list --assignee "$ME" --all \
    --query "[?contains(scope, '/resourceGroups/$RG')].id" -o tsv); do
  az role assignment delete --ids "$id"
done

az lock delete --name do-not-delete-terraform-state --resource-group "$RG" \
  --resource "$SA" --resource-type Microsoft.Storage/storageAccounts

az group delete --name "$RG"                        # prompts for confirmation
```

## 5. Purge what soft delete kept

```bash
az keyvault list-deleted --query "[?name=='$KV']" -o table
az keyvault purge --name "$KV" --location "$LOCATION"
```

Purge protection is off in this demo, which is why this works. The trade-off
is in the README.

## 6. GitHub

The repository stays public as the record of the work. The variables are
identifiers of things that no longer exist; remove them anyway, with the
environment, so nothing points at a deleted tenant object.

```bash
for v in AZURE_TENANT_ID AZURE_SUBSCRIPTION_ID AZURE_PLAN_CLIENT_ID AZURE_APPLY_CLIENT_ID; do
  gh variable delete "$v" --repo adamabdo-xynora/portfolio-on-azure
done
gh api --method DELETE repos/adamabdo-xynora/portfolio-on-azure/environments/azure-demo
```

## 7. Confirm nothing billable remains

Each of these should print nothing, `false`, or `[]`:

```bash
az group exists --name "$RG"
az resource list --tag project=portfolio-on-azure -o table
az keyvault list-deleted -o table
az monitor log-analytics workspace list-deleted-workspaces -o table
az ad app list --display-name github-portfolio-on-azure -o table
az role definition list --custom-role-only true -o table
az role assignment list --all --query "[?principalType=='ServicePrincipal' && contains(scope, '$RG')]" -o table
az consumption budget list -o table
```

Then check spend for the rest of the month in the portal (Cost Management →
Cost analysis, scope: the subscription). Cost data lags usage by 8–24 hours,
so a charge from the last day of running can appear after teardown. It is
the last such charge. The resource providers registered by bootstrap stay
registered; registration is free and has no effect on its own.
