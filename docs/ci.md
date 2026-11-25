# CI / GitHub Actions

All workflows authenticate via **GitHub OIDC** (no stored AWS keys). The OIDC
provider is created at bootstrap and the CI role in the `iam` layer; store the
role ARN as the repo **variable** `AWS_TERRAFORM_ROLE_ARN` (a secret with the
same name also works as a fallback, but ARNs aren't sensitive).

## Start / stop / checks (`sok-start.yml`, `sok-stop.yml`, `sok-checks.yml`)

The power and checks workflows target the `eks` + `sok` layers (the persistent
`account` layer is never touched):

- **SOK START** applies `eks` then `sok`; passes the runner's egress IP as
  `eks_public_access_cidrs` (appended to `trusted_cidrs`) so the runner reaches
  the K8s API during the apply. ~20–25 min wall clock.
- **SOK STOP** is a full **destroy** of `sok` then `eks`, the only route to ~$0
  overnight, since an EKS control plane bills whether or not it's used. It
  reclaims PVC EBS volumes in order (namespace delete before cluster delete) and
  verifies no cluster/EBS/ELB remains. Nightly at **21:30 UTC** (dev). A **prod**
  stop requires a typed `confirm=prod` on dispatch.
- **SOK CHECKS** runs `sok-health.sh` via `kubectl exec` with a 12×2-min retry
  envelope after a successful START; each run temporarily allowlists the runner
  IP on the EKS API.

## App deploys (`deploy-apps.yml`)

Manual **workflow_dispatch** only (never on push); pick `env` (dev/prod) and
`scope`:

- `all`, sync every tier prefix (`make sok-deploy-apps`) **and** build+ship
  the SOK console add-on.
- `cm` / `sh` / `idx` / `shc`, sync a single tier prefix (passed straight to
  `scripts/package-apps.sh`). There is no `mc` scope yet.
- `console`, build+ship only `Splunk_TA_sok_console`.

A **prod** deploy requires `confirm=prod` on dispatch (mirrors `sok-stop.yml`);
dev needs no confirmation.

The **console** job checks out the private `livehybrid/splunk-sok-console` repo,
runs `ucc-gen build`, repackages the versionless `Splunk_TA_sok_console/` output
into a deterministic tgz (same recipe as `package-apps.sh`) and `aws s3 cp`s it
to `s3://livehybrid-splunk-<env>-splunk-apps-<env>/sh-apps/Splunk_TA_sok_console.tgz`
(the Standalone SH's appSource). It authenticates to the private console repo
with the existing `/git/login` Secrets Manager token by default; set an optional
`CONSOLE_REPO_PAT` repo secret (fine-grained PAT with read on the console repo)
if that token lacks read scope there.

!!! note "Runs from master only"
    The OIDC trust is scoped to `ref:refs/heads/master`, so this workflow (like
    the others) can only assume the AWS role when dispatched from `master`. Merge
    it before running.

## On-demand operations workflows

`workflow_dispatch` workflows wrap the operational make targets so routine
estate tasks run from the Actions tab with the same OIDC role, `eu-west-2`
region and per-env concurrency guard as the power workflows. All are manual only
(no `push`/`pull_request`), except the KV-store backup which also runs nightly.
Prod paths that touch the live estate require a typed `confirm=prod`.

| Workflow (`file`) | Wraps | Triggers | Gate |
|---|---|---|---|
| **SOK KV-STORE BACKUP** (`sok-kvstore-backup.yml`) | `make sok-kvstore-backup env=<env>` | dispatch + **schedule** (nightly 22:15 UTC, prod) | none (read-side backup, low risk) |
| **SOK RF REMEDIATE** (`sok-rf-remediate.yml`) | `make sok-rf-remediate env=<env>` | dispatch | none (safe no-op when healthy) |
| **TERRAFORM PLAN** (`terraform-plan.yml`) | `make -C terraform/layers/<layer> terraform-plan env=<env>` | dispatch | none (read-only plan) |

Inputs:

- **SOK KV-STORE BACKUP**, `env` (dev/prod, default prod). The nightly cron only
  ever targets prod (the dev SOK is rebuilt nightly, so its KV store is
  disposable).
- **SOK RF REMEDIATE**, `env` (dev/prod, default dev). Fixes the SmartStore
  cold-boot RF/SF stall; a no-op once the cluster is at RF+SF.
- **TERRAFORM PLAN**, `env` (prod/dev), `layer` (all = account→iam→eks→sok in
  order, or a single layer). **Read-only**: it runs `terraform plan` only and
  never applies. Per the `terraform-ci.yml` caveat (a plan against live state can
  echo resource attributes into the log), the human-readable plan is redirected
  to a file that is not surfaced; the summary reports no-change / changes-pending
  / error only, and no `-json` plan is ever dumped to the console.

## Plan / validate CI (`terraform-ci.yml`)

Runs on PRs touching `terraform/**`: `fmt -check -recursive`, per-layer
backendless `validate` (all layers) and shellcheck. A post-apply drift check
(`plan -detailed-exitcode`, warn) runs at the end of `sok-start.yml`.

## Cost estimation (`infracost.yml`)

Runs on every PR touching `terraform/**`; posts/updates one comment with
per-(layer × workspace) monthly cost. Projects are defined in `infracost.yml`
(note: `terraform_var_files` are **relative to each project path**, hence
`../_shared/vars/<env>.tfvars`). Requires the `INFRACOST_API_KEY` repo secret.

Local: `make infracost-breakdown` / `make infracost-diff`.

## Docs (`docs.yml`)

Builds this MkDocs site and deploys it to **GitHub Pages**.

Local preview: `make docs-serve`.
