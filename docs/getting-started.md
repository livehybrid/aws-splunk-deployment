# Getting started

## Apply order

Per workspace (`prod`, `dev`), the bring-up order is:

1. **bootstrap** (out-of-band), the state bucket and the GitHub OIDC provider.
2. **Terraform layers, strictly in order** (outputs feed forward):
   `account` → `iam` → `eks` → `sok`.

```sh
make terraform env=dev    # walks account → iam → eks → sok
```

The `account` layer holds the persistent data (SmartStore + apps + KV-backup
S3 buckets, KMS, the HEC-token secret) and is applied once. `eks` and `sok` are
the disposable compute: `eks` is the cluster, node groups, addons and
StorageClasses; `sok` is the operator, the CRDs and the Splunk Custom
Resources.

## First deploy from zero

One-time prerequisites before the first `make terraform` in a fresh account:

1. **State bucket**, the `<account-alias>-terraform` S3 bucket referenced by
   each layer's backend config must exist (versioned, encrypted). Create it as
   part of bootstrap; the account layer then attaches its bucket policy.
2. **Route53 public hosted zone** for the external domain, external web/HEC
   DNS records are written into it, so it must be delegated and resolving
   first.
3. **Workspaces**, on first init in each layer:
   `terraform workspace new dev` (and `prod`).
4. **Operator-supplied secrets**, create before the sok layer applies:

   ```sh
   aws secretsmanager create-secret --name /monitoring/splunk/license \
     --secret-string file://enterprise.lic
   aws secretsmanager create-secret --name /git/login \
     --secret-string '<github-pat-with-repo-read>'
   aws secretsmanager create-secret --name /monitoring/alerts/slack_webhook \
     --secret-string 'https://hooks.slack.com/services/...'
   ```

   The Splunk admin password (`/<env>/splunk/password` for dev,
   `/monitoring/splunk/password` for prod) and `/splunk/pass4SymmKey` seed the
   operator global secret (`splunk-<ns>-secret`), rotate their values after
   the first apply if you didn't set them deliberately.

5. **GitHub Actions OIDC** (for CI start/stop/checks): the OIDC provider is
   created at bootstrap and the CI role in the `iam` layer. Store the printed
   role ARN as the repo variable `AWS_TERRAFORM_ROLE_ARN`.

## Verifying a deploy

```sh
make kubeconfig env=dev   # point kubectl at the splunk-sok-<env> EKS cluster
make sok-status env=dev   # CR phases (CM / IndexerCluster / Standalone / LM / MC) + pods
make sok-health env=dev   # deep Splunk checks via kubectl exec: RF/SF, SHC, KV store, licence
```

A cold boot against a populated SmartStore bucket can take a few minutes to
meet RF/SF. `sok-health` is meaningful only once the CRs reach `Ready`. The
[SOK CHECKS workflow](ci.md) runs the same checks automatically after every
SOK START with retries to ride out this window. See the
[operations runbook](kubernetes-sok-runbook.md) for the full day-2 flow.

## Local docs

```sh
make docs-serve   # live-preview this site on http://127.0.0.1:8000
make docs-build   # strict build (same as CI)
```
