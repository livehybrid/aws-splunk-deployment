# Getting started

## Apply order

Per workspace (`prod`, `dev`):

1. **Packer** — build the Splunk Enterprise AMI, paste the AMI ID into
   `terraform/layers/_shared/vars/<env>.tfvars`.
2. **Terraform layers, strictly in order** (outputs feed forward):
   `account` → `iam` → `cluster`.

```sh
make splunk-versions                  # look up current Splunk 10.x + build
make packer-build-splunk env=prod     # build AMI (or use the GitHub Action)
# paste AMI ID into terraform/layers/_shared/vars/prod.tfvars
make terraform env=prod               # walks account → iam → cluster
```

## First deploy from zero

One-time prerequisites before the first `make terraform` in a fresh account:

1. **State bucket** — the `<account-alias>-terraform` S3 bucket referenced by
   each layer's backend config must exist (versioned, encrypted). Create it
   manually; the account layer then attaches its bucket policy.
2. **Route53 public hosted zone** for the external domain — ACM certificate
   validation in the cluster layer writes records into it, so it must be
   delegated and resolving first.
3. **Workspaces** — on first init in each layer:
   `terraform workspace new prod` (and `dev`).
4. **Operator-supplied secrets** — create before the cluster layer applies:

   ```sh
   aws secretsmanager create-secret --name /monitoring/splunk/license \
     --secret-string file://enterprise.lic
   aws secretsmanager create-secret --name /git/login \
     --secret-string '<github-pat-with-repo-read>'
   aws secretsmanager create-secret --name /monitoring/alerts/slack_webhook \
     --secret-string 'https://hooks.slack.com/services/...'
   ```

   `/monitoring/splunk/password` and `/splunk/pass4SymmKey` are created by the
   iam layer itself — rotate their values after the first apply if you didn't
   set them deliberately (`make rotate-admin env=prod` handles the admin
   password fleet-wide).

5. **GitHub Actions OIDC** (optional, for CI start/stop/checks): run
   `./scripts/setup-github-oidc.sh livehybrid/aws-splunk-cluster` and store
   the printed role ARNs as repo variables `AWS_PACKER_ROLE_ARN` and
   `AWS_TERRAFORM_ROLE_ARN`.

## Verifying a deploy

```sh
make smoke env=prod    # AWS-side: ASGs, target groups, DNS, S3
make health env=prod   # Splunk-side via SSM: RF/SF, SHC, KV store, licence, MC
```

Bootstrap takes ~5-10 min after instance launch; a cold boot against a
populated SmartStore bucket can take a few minutes more to meet RF/SF.
`health` is meaningful only once `smoke` passes. The
[checks workflow](ci.md) runs both automatically after every CI START with
retries to ride out this window.

## Local docs

```sh
make docs-serve   # live-preview this site on http://127.0.0.1:8000
make docs-build   # strict build (same as CI)
```
