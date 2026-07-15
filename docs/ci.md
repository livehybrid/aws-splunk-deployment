# CI / GitHub Actions

This is the single CI reference for the repo and covers **both** deployment
models: the EC2 workflows (Packer, start/stop/checks, deploy-apps) and their
[SOK counterparts](#sok-sok-startyml-sok-stopyml-sok-checksyml). All workflows
authenticate via **GitHub OIDC** (no stored AWS keys). One-time setup:
`./scripts/setup-github-oidc.sh livehybrid/aws-splunk-cluster`, then
store the printed role ARNs as repo **variables** `AWS_PACKER_ROLE_ARN` and
`AWS_TERRAFORM_ROLE_ARN` (a secret with the same name also works as a
fallback, but ARNs aren't sensitive).

## Packer AMI build (`packer.yml`)

Manual **workflow_dispatch** with `env` input; optionally opens a PR bumping
`splunk_ami` in the tfvars.

## Start / stop (`splunk-start.yml`, `splunk-stop.yml`)

One-click cluster power controls (Actions tab → run workflow → pick env):

- **start** applies the cluster layer with `<env>.tfvars`.
- **stop** applies the `<env>-shutdown.tfvars` overlay (destroys instances,
  EBS, ALB/NLBs — keeps S3 data, KMS, Secrets, Route53, IAM, ACM; residual
  ≈$8/mo), verifies nothing costly is left, and **retries once** if the
  first apply hits the EIP-release race.
- Stop also runs **nightly at 22:30 UTC** as a cost guard — comment out the
  `schedule:` block when working late.

## Checks (`splunk-checks.yml`)

Runs `smoke-test.sh` (AWS-side) and `cluster-health.sh` (Splunk-side via
SSM) from a runner — manually (pick env + which checks), and automatically
after every successful **START** with **12×2-min retries** to ride out the
cold-boot window. If RF fixups stall on the known legacy-bucket signature,
the workflow calls `scripts/rf-remediate.sh` once mid-window. Results land
in the run's step summary.

## App deploys (`splunk-deploy-apps.yml`)

workflow_dispatch → pick env + scope (`idx` / `shc` / `ds` / `cm` / `all`);
wraps `scripts/deploy-apps.sh` — same behaviour as `make deploy-apps`.

## SOK app deploys (`deploy-apps.yml`)

The `deployment_model=sok` counterpart of `splunk-deploy-apps.yml`. Manual
**workflow_dispatch** only (never on push); pick `env` (dev/prod) and `scope`:

- `all` — sync every tier prefix (`make sok-deploy-apps`) **and** build+ship
  the SOK console add-on.
- `cm` / `sh` / `idx` / `shc` — sync a single tier prefix (passed straight to
  `scripts/package-apps.sh`). There is no `mc` scope yet (see the
  [A1 handoff](handoff-sok-lessons-remainder.md#a1-mc-app-delivery-path-unblocks-the-mc-apply-automation)).
- `console` — build+ship only `Splunk_TA_sok_console`.

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

## SOK (`sok-start.yml`, `sok-stop.yml`, `sok-checks.yml`)

The `deployment_model=sok` counterparts of the power/checks workflows, targeting
the eks + sok layers (the persistent `sok-foundation` is never touched):

- **SOK START** applies eks then sok; passes the runner's egress IP as
  `eks_public_access_cidrs` (appended to `trusted_cidrs`) so the runner reaches
  the K8s API during the apply.
- **SOK STOP** is a full **destroy** of sok then eks — the only route to ~$0
  overnight, since an EKS control plane bills whether or not it's used. It
  reclaims PVC EBS volumes in order (namespace delete before cluster delete) and
  verifies no cluster/EBS/ELB remains. Nightly at **21:30 UTC**.
- **SOK CHECKS** runs `sok-health.sh` via `kubectl exec` with the same 12×2-min
  retry envelope after a successful START; each run temporarily allowlists the
  runner IP on the EKS API.

## On-demand operations workflows

Six `workflow_dispatch` workflows wrap the operational make targets so routine
estate tasks run from the Actions tab with the same OIDC role, `eu-west-2`
region and per-env concurrency guard as the power workflows. All are manual only
(no `push`/`pull_request`), except the KV-store backup which also runs nightly.
Prod paths that touch the live estate require a typed `confirm=prod`.

| Workflow (`file`) | Wraps | Triggers | Gate |
|---|---|---|---|
| **SOK KV-STORE BACKUP** (`sok-kvstore-backup.yml`) | `make sok-kvstore-backup env=<env>` | dispatch + **schedule** (nightly 22:15 UTC, prod) | none (read-side backup, low risk) |
| **MC REGISTER** (`mc-register.yml`) | `make mc-register env=<env>` | dispatch | none (idempotent SSM re-register) |
| **SOK RF REMEDIATE** (`sok-rf-remediate.yml`) | `make sok-rf-remediate env=<env>` | dispatch | none (safe no-op when healthy) |
| **ROLLING RESTART** (`rolling-restart.yml`) | `make rolling-restart env=<env> role=<indexer\|searchhead>` | dispatch | **confirm=prod** for prod (bounces live peers/members) |
| **ROTATE ADMIN** (`rotate-admin.yml`) | `make rotate-admin env=<env>` | dispatch | **confirm=prod** for prod |
| **TERRAFORM PLAN** (`terraform-plan.yml`) | `make -C terraform/layers/<layer> terraform-plan env=<env>` | dispatch | none (read-only plan) |

Inputs:

- **SOK KV-STORE BACKUP** — `env` (dev/prod, default prod). The nightly cron only
  ever targets prod (the dev SOK is rebuilt nightly, so its KV store is
  disposable).
- **MC REGISTER** — `env` (prod/dev). EC2 estate; runs `mc-register-peers.sh` on
  the MC over SSM. Run after a recycle when peer IPs change.
- **SOK RF REMEDIATE** — `env` (dev/prod, default dev). Fixes the SmartStore
  cold-boot RF/SF stall; a no-op once the cluster is at RF+SF.
- **ROLLING RESTART** — `env` (prod/dev), **required** `role` (indexer =
  CM-coordinated peer restart, searchhead = SHC rolling restart), `confirm`.
- **ROTATE ADMIN** — `env` (prod/dev), `confirm`. Rotates the `splunkadmin`
  password fleet-wide. **The new secret never leaves Secrets Manager**: the
  workflow does not enable `set -x`, does not `tee`/print the target output, and
  reports pass/fail only, so no password lands in the log. Read it back with
  `make password`.
- **TERRAFORM PLAN** — `env` (prod/dev), `layer` (all = account→iam→cluster in
  order, or a single layer). **Read-only**: it runs `terraform plan` only and
  never applies. Per the `terraform-ci.yml` caveat (a plan against live state can
  echo resource attributes into the log), the human-readable plan is redirected
  to a file that is not surfaced; the summary reports no-change / changes-pending
  / error only, and no `-json` plan is ever dumped to the console.

## Cost estimation (`infracost.yml`)

Runs on every PR touching `terraform/**`; posts/updates one comment with
per-(layer × workspace) monthly cost. Projects are defined in `infracost.yml`
(note: `terraform_var_files` are **relative to each project path**, hence
`../_shared/vars/<env>.tfvars`). Requires the `INFRACOST_API_KEY` repo secret.

Local: `make infracost-breakdown` / `make infracost-diff`.

To (re)baseline after a prod apply:
`infracost breakdown --config-file=infracost.yml --format=json --out-file=infracost-base.json`
committed on the default branch turns future PR comments into cost-diffs.

## Docs (`docs.yml`)

Builds this MkDocs site and deploys it to **GitHub Pages**.

Local preview: `make docs-serve`.
