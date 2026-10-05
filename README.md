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
- [`docs/secrets.md`](docs/secrets.md): how secret values are set without touching Terraform, GitHub or this repo
- [`docs/teardown.md`](docs/teardown.md): how to remove all of it
