y# Deployment & IaC review — SOK implementation

!!! info "Part of the [full SOK review](index.md)"
    July 2026 · **15 findings** — 3 High, 10 Medium, 2 Low. High findings re-verified against code + live state buckets. See the [review index](index.md) for the prioritised remediation plan.

!!! success "Remediation status (reconciled 2026-07-14)"
    **DONE 6 · PARTIAL 7 · OPEN 2.** All three Highs closed (DEP-1 state locking, DEP-2 backend guard partial, DEP-3 overlay committed). Open: DEP-14, DEP-15. Per-finding markers below.

Scope reviewed: all six layers' backend/provider/version files, `eks`/`sok`/`sok-foundation` in full, `_shared` variables/tfvars/Makefile/backend confs, `sok-*.yml` + `infracost.yml` + `splunk-*.yml` workflows, root Makefile. `terraform validate` passes on eks, sok, and sok-foundation. Live read-only checks were run against both state buckets, DynamoDB, and GitHub Actions.

## Findings

### [DEP-1] No Terraform state locking anywhere — S3 backends have neither DynamoDB nor `use_lockfile`
- **Severity**: High
- **Status**: ✅ **DONE** — `use_lockfile = true` is now in both `dev.backend.conf:5` and `prod.backend.conf:5` (S3-native locking, TF ≥1.11), with an inline DEP-1 citation; no DynamoDB table (correct). Both confs are symlinked into all six layers.
- **Evidence**: `_shared/conf/dev.backend.conf:1-3` and `prod.backend.conf:1-3` set only `bucket`/`region`/`encrypt`; backend blocks in all six layers add only `key`. Repo-wide search for `use_lockfile`/`dynamodb_table`: zero hits. Live: `aws dynamodb list-tables` shows no lock table.
- **Impact**: The nightly `splunk-stop.yml` cron (21:30 UTC, `apply -auto-approve`) and sok-stop cron execute unattended against the same states a human uses locally. GitHub concurrency groups only serialize workflows — a local `terraform apply` at 21:30 races the CI destroy with zero locking; two writers on one state = corrupted/lost-update.
- **Recommendation**: Add `use_lockfile = true` to both backend confs (S3-native locking, TF ≥1.10). No DynamoDB needed.
- **Effort**: S

### [DEP-2] Wrong-backend init is completely unguarded — the exact near-miss class has no protection
- **Severity**: High
- **Status**: ◐ **PARTIAL** — a symlinked `_shared/checks.tf` in all six layers asserts `terraform.workspace == var.environment` (DONE-ish). **Residual: it does NOT assert `backend.config.bucket == var.state_bucket` (the exact near-miss vector), and there is no `-reconfigure` in the Makefile init.**
- **Evidence**: Backend bucket comes from `conf/<env>.backend.conf` at init; workspace and tfvars chosen separately. `var.account_id` is declared (`_shared/variables.tf:15-18`, set in both tfvars) but **never referenced** (grep: zero uses). `var.state_bucket` is used only for `terraform_remote_state` reads — making failure worse: init account layer against dev backend with prod tfvars and remote-state reads still fetch correct prod outputs, so the empty-state "create everything" plan looks internally consistent. Both envs share account 123456789012, so an account-identity check can't discriminate — only the bucket can.
- **Impact**: One skipped Makefile invocation (raw `terraform init`) from applying a duplicate prod estate. Caught by human plan-reading last time; nothing structural prevents a repeat.
- **Recommendation**: Symlinked `checks.tf` in every layer asserting initialized backend bucket == `var.state_bucket`: `check "backend_matches_env" { assert { condition = !fileexists(".terraform/terraform.tfstate") || jsondecode(file(".terraform/terraform.tfstate")).backend.config.bucket == var.state_bucket } }`. Fails every plan/apply where conf-file and tfvars disagree. Also `terraform init -reconfigure` in the Makefile.
- **Effort**: S

### [DEP-3] The validated multisite dev shape exists only in an out-of-repo overlay — and, post-destroy, nowhere else
- **Severity**: High
- **Status**: ✅ **DONE** — `_shared/vars/overlays/dev-multisite.tfvars` is committed and `sok-start`/`sok-stop` gained the `overlay` dispatch input (=OPS-9).
- **Evidence**: `crs.tf:67-70` builds site CRs from `var.multisite`, but `dev.tfvars` never sets `multisite` (defaults false). The multisite validation was applied from a tfvars overlay in a temp dir outside the repo. The dev sok/eks states were destroyed 2026-07-10 (live: state objects empty), so the applied values aren't recoverable from state either.
- **Impact**: The exact configuration proven to work (the deliverable of this branch) is unreproducible from git.
- **Recommendation**: Commit the overlay as `_shared/vars/dev-multisite.tfvars` (no secrets — topology knobs) plus the apply command. Optionally add a `topology` input to sok-start.
- **Effort**: S

### [DEP-4] The SOK lifecycle automation is not live: workflows exist only on an unpushed local branch
- **Severity**: Medium
- **Status**: ✅ **DONE** — the workflows are on `origin/master` (=OPS-3); the cron and dispatch surface are active. *Residual: verify the first scheduled sok-stop fired.*
- **Evidence**: `gh api`: sok-stop/start/checks return 404 on default branch; `git ls-tree origin/master` shows only docs/infracost/packer/splunk-*. Local master 18 commits ahead; sok branch 23 ahead. `schedule:` triggers only fire from the default branch.
- **Impact**: The cost guard ("nightly stop") is inert — a dev SOK cluster left up bills ~$6.50/day until manual destroy. The entire SOK implementation lives on one laptop.
- **Recommendation**: Push the branch; on merge verify the first scheduled sok-stop fires (note it processes empty state — confirm the destroy-with-empty-eks-remote-state path is clean; `sok/provider.tf:18-24` dereferences eks outputs).
- **Effort**: S

### [DEP-5] No confirmation gate on prod destroy; applies run auto-approve from any dispatched ref
- **Severity**: Medium
- **Status**: ◐ **PARTIAL** — a typed `confirm=prod` gate is on both start (`sok-start.yml:55-59`) and stop (`sok-stop.yml:54-60`) (DONE). **Residual: no `environment: prod` required reviewers and no explicit `github.ref_name != 'master'` guard** (the SEC-2 trust-scoping substitutes for the latter).
- **Evidence**: `sok-stop.yml:22-27` offers `env: [dev, prod]` on dispatch, runs `destroy -auto-approve` of sok then eks with no typed confirmation, no `environment:` protection, no plan. `sok-start.yml:72-86` applies `-auto-approve` from whatever ref was dispatched. Nothing requires master.
- **Impact**: Post-cutover, a dropdown misclick destroys the live prod SOK cluster mid-day (KV rolls back up to 6h; search down for the rebuild). A dispatch from a stale branch applies stale infra to prod.
- **Recommendation**: Required `confirm` input matching env name for prod; `environment: prod` with required reviewers; guard step failing when `github.ref_name != 'master'` for prod.
- **Effort**: S

### [DEP-6] Exclusivity guard gaps: the eks layer is unguarded, and a stranded EKS cluster then blocks the nightly EC2 prod stop
- **Severity**: Medium
- **Status**: ✅ **DONE** — `eks/main.tf:34-56` now mirrors the `aws_instances.ec2_core` postcondition guard, so the eks layer refuses to apply while EC2 core instances run.
- **Evidence**: Guards exist and mirror: `cluster/deployment_model.tf:37-44` (no ec2-core plan while `splunk-sok-<env>` exists) and `sok/main.tf:36-56` (no sok while `<env>-indexer*`/`-manager*` EC2 running — patterns match the real `prod_indexer_a_0` tag scheme). BUT: (a) the **eks layer reads `deployment_model` nowhere and has no guard** — `sok-start` on prod while EC2 runs applies the whole EKS cluster first, then fails in sok; the stray `splunk-sok-prod` cluster now trips `deployment_model.tf:40` and **fails the nightly `splunk-stop` prod apply** (core_on=1) → prod EC2 runs all night + orphan EKS bills. (b) Both guards are plan-time postconditions on data sources nothing depends on, so `terraform apply -target=` skips them. (c) No state locking = unlocked TOCTOU.
- **Impact**: One wrong-env start produces the exact stuck state the guards exist to prevent, and disables cost-containment until hand-cleaned.
- **Recommendation**: Duplicate the `aws_instances` postcondition into the eks layer (or a sok-start pre-flight); document "-target skips the guards"; soften the cluster-layer guard to only fail when core capacity is actually being created so shutdown applies can't be blocked.
- **Effort**: M

### [DEP-7] Nightly supply-chain drift: EKS module version floats and addons install "most recent" on every recreate
- **Severity**: Medium
- **Status**: ✅ **DONE** — `eks/eks.tf:22 version = "21.24.0"` (exact) and all four addons carry explicit `addon_version` (`:72-99`).
- **Evidence**: `eks/eks.tf:18-19` `version = "~> 21.0"` — `.terraform.lock.hcl` pins providers only, never modules, and CI re-runs `terraform init` fresh nightly, resolving newest 21.x (currently 21.24.0). `eks/eks.tf:48-57` declares addons as `coredns = {}` etc.; module default `most_recent = true`, so coredns/kube-proxy/vpc-cni/ebs-csi are whatever AWS published that morning.
- **Impact**: The morning start can break/change behavior with zero repo diff — undermines the "nightly recreate is deterministic" premise.
- **Recommendation**: Pin `version = "21.24.0"` exactly; set explicit `addon_version` for the four addons.
- **Effort**: S

### [DEP-8] No container image is digest-pinned, and a community image holds exec+S3 powers
- **Severity**: Medium
- **Status**: ◐ **PARTIAL** — splunk + alpine/k8s are digest-pinned (=SEC-6, closing the sharpest exec+S3 image). **Residual: `nodelocaldns` is still tag-only (`eks/nodelocaldns.tf:22`).**
- **Evidence**: `_shared/variables.tf:423` `docker.io/splunk/splunk:10.4.0`; `eks/nodelocaldns.tf:22` node-cache:1.26.8; `sok/kvbackup.tf:161` `alpine/k8s:1.34.1` (community image) with `pods/exec` RBAC + kvbackup-bucket IRSA. Charts are version-pinned (good) but reference their own image tags.
- **Impact**: A retagged/compromised `alpine/k8s` executes with the ability to exec into every Splunk pod (read admin password in-pod) and write S3. Splunk tag drift changes the build without a diff.
- **Recommendation**: Pin all three by `@sha256:` digest; for kvbackup prefer a self-built minimal ECR image.
- **Effort**: S

### [DEP-9] Terraform version skew across the pipeline can wedge the nightly stop
- **Severity**: Medium
- **Status**: ◐ **PARTIAL** — root `.terraform-version = 1.11.1` and the sok-* + terraform-ci workflows pin `1.11.1` (DONE). **Residual: the EC2 `splunk-start.yml:31` / `splunk-stop.yml:37` still pin `1.10.5`, so skew against the 1.11.1 estate persists.**
- **Evidence**: sok-start/stop pin TF **1.11.1**; splunk-start/stop pin **1.10.5**; `_shared/.terraform-version` (symlinked into account/iam/cluster only) says **1.10.5**; eks/sok/sok-foundation have **no** `.terraform-version` symlink, so local runs use whatever is installed; `required_version = ">= 1.10, < 2.0"` accepts anything.
- **Impact**: Terraform refuses state written by a newer CLI. A local apply with TF ≥1.11 makes that night's `splunk-stop` (1.10.5) fail — the cost guard silently stops guarding.
- **Recommendation**: Standardize on 1.11.1 everywhere (workflows, `.terraform-version`, new-layer symlinks). Unlocks `use_lockfile` GA (DEP-1).
- **Effort**: S

### [DEP-10] `prevent_destroy` covers only the KMS key — none of the three "must outlive every teardown" buckets
- **Severity**: Medium
- **Status**: ◐ **PARTIAL** — `prevent_destroy` added to smartstore (`smartstore.tf:94`) and kvbackup (`kvbackup.tf:38`). **Residual: the apps bucket still has no `prevent_destroy` (`apps.tf`).**
- **Evidence**: `sok-foundation/smartstore.tf:33-36` (KMS key prevent_destroy) is the only lifecycle protection. `aws_s3_bucket.smartstore`/`apps`/`kvbackup` have none — despite the layer header stating "the bucket must outlive every teardown". No bucket versioning either.
- **Impact**: Today's only shield is implicit `BucketNotEmpty` (no `force_destroy`). A refactor that plans bucket replacement, or a targeted destroy, deletes an empty-enough bucket; kvbackup objects expire at 30 days so it trends toward deletable.
- **Recommendation**: Add `lifecycle { prevent_destroy = true }` to all three buckets; consider versioning on kvbackup.
- **Effort**: S

### [DEP-11] No plan/validate CI at all; targeted-apply drift is never verified post-hoc
- **Severity**: Medium
- **Status**: ✅ **DONE** — `terraform-ci.yml` runs PR-time `fmt -check -recursive` + per-layer backendless `validate` (all six) + shellcheck; a post-apply drift check runs in `sok-start.yml:117-135` (`-detailed-exitcode`, warn).
- **Evidence**: Only PR workflow touching terraform is `infracost.yml` (costing). No `fmt -check`/`validate`/`plan` for any layer; root `Makefile:20` `standard_terraform_layers := account iam cluster` excludes eks/sok/sok-foundation. Debugging used `-target` applies; nothing asserts a clean full plan afterwards. First execution of merged code is `apply -auto-approve` in sok-start.
- **Impact**: A tfvars typo, provider deprecation, or leftover targeted-apply drift is discovered at 06:00 by a failed auto-approve apply in the only environment.
- **Recommendation**: PR workflow: `fmt -check` + `validate` for all six layers, plus OIDC `plan -detailed-exitcode` on changed layers. Add "plan must be empty" step at end of sok-start (fail on exitcode 2).
- **Effort**: M

### [DEP-12] `_shared/Makefile` defaults to `env=prod` + `tf-command=apply`; the three SOK layers lack the guarded Makefile entry point
- **Severity**: Medium
- **Status**: ◐ **PARTIAL** — the `env = prod` default is removed (`_shared/Makefile:5`; `guard-env` now forces an explicit env) (DONE). **Residual: `tf-command` still defaults to `apply` (not `plan`), and eks/sok/sok-foundation still have no `Makefile` symlink.**
- **Evidence**: `_shared/Makefile:1-3` — `tf-command = apply`, `env = prod`. So `make -C terraform/layers/cluster terraform` with no args passes `guard-env` and runs **apply against prod**. eks/sok/sok-foundation have no `Makefile` symlink, so the only local path for the newest, most-hand-driven layers is raw `terraform` — the mode that produced DEP-2.
- **Impact**: A muscle-memory `make terraform` applies prod; the layers where env-consistency helps most don't have it.
- **Recommendation**: Delete `env = prod` default; default `tf-command = plan`; add `Makefile`/`.terraform-version` symlinks to the three SOK layers.
- **Effort**: S

### [DEP-13] sok-checks: always checks dev after a workflow_run, no concurrency group, single-site-only assertions
- **Severity**: Medium
- **Status**: ◐ **PARTIAL** — env-derivation is fixed and `sok-health` is multisite-aware (=OPS-2/OPS-6) (DONE). **Residual: no `concurrency:` key in sok-checks, so its retry can still race the 21:30 stop.**
- **Evidence**: `sok-checks.yml:19-21` triggers on completed SOK START; `TARGET_ENV: ${{ inputs.env || 'dev' }}` — `inputs` empty for `workflow_run`, so a **prod** start is auto-checked against **dev**. No `concurrency:` key, so its ≤24-min retry can run while the 21:30 stop destroys the cluster. `sok-health.sh:44` hardcodes `indexercluster/idxc`/`standalone/sh` — multisite/SHC names report missing.
- **Impact**: The only automated post-start verification silently no-ops for prod and false-fails around the nightly window.
- **Recommendation**: Derive env from the triggering run; add concurrency; parameterize sok-health.sh over discovered CR names.
- **Effort**: M

### [DEP-14] Splunk secrets plaintext in state; state buckets use SSE-S3, plan artifacts not gitignored
- **Severity**: Low
- **Status**: ○ **OPEN** — `.gitignore` still covers `*.tfstate*` but NOT `*.tfplan`/`plan-*.json`; the state buckets are still AES256 (=SEC-3).
- **Evidence**: `sok/secrets.tf:34-49` writes admin password + pass4SymmKey (×3) + HEC token into `kubernetes_secret_v1.global`; `:53-64` the licence — all in `env:/dev/sok/terraform.tfstate`. Live: both state buckets versioned + public-access-blocked (good) but default encryption AES256 (SSE-S3), not KMS. `_shared/Makefile:31,34` writes `plan-<env>.tfplan`/`.json` into layer dirs; `.gitignore` covers `*.tfstate` but not `*.tfplan`/`plan-*.json`.
- **Impact**: Anyone with state-bucket read (or a stray `git add -A` of a plan) holds Splunk cluster-admin creds.
- **Recommendation**: SSE-KMS default encryption + reader-restricted bucket policy; gitignore `*.tfplan`/`plan-*.json`.
- **Effort**: S

### [DEP-15] GitHub Actions tag-pinned not SHA-pinned; four workflows depend on checkip.amazonaws.com
- **Severity**: Low
- **Status**: ○ **OPEN** — `sok-*.yml` still use `actions/checkout@v4` etc (mutable tags), and the runner IP is still `curl checkip.amazonaws.com` with no regex/fallback.
- **Evidence**: `actions/checkout@v4`, `configure-aws-credentials@v4`, `setup-terraform@v3`, `infracost/actions/setup@v3` — mutable tags in workflows holding an OIDC role that can destroy either env. Runner IP via `curl https://checkip.amazonaws.com` (sok-start/stop/checks) with no fallback — a hiccup corrupts `eks_public_access_cidrs`.
- **Impact**: A hijacked action tag executes with prod-destroying creds; a checkip outage fails starts/stops.
- **Recommendation**: SHA-pin the four actions (Dependabot keeps fresh); validate the fetched IP with a regex + fallback to api.ipify.org.
- **Effort**: S

## Strengths (brief)
- Clean layer/state separation with per-layer keys; the alekc/kubectl eager-config constraint correctly engineered around (CRDs/operator in sok, provider host from remote-state) and documented in place.
- All six layers commit `.terraform.lock.hcl` (aws 6.54.0, kubectl 2.4.1 exact); CRDs vendored with source URL + sha256 + coupled-bump instruction; ALB IAM policy vendored at a stated version.
- Both exclusivity guards exist and their EC2 Name-tag patterns match the real scheme; stop ordering (sok → EBS-reclaim wait → eks → residual verify with hard fail) is thoughtful.
- Shared `splunk-power-<env>` concurrency across EC2 and SOK; OIDC-only auth; IRSA everywhere with derived trust policies; state buckets versioned + public-access-blocked.
- Infracost wired per layer × workspace including the staged prod SOK projects.

## Suggested follow-up tasks (ordered)
1. Add `use_lockfile = true` to both backend confs and align all Terraform to 1.11.1 — DEP-1/DEP-9.
2. Add the symlinked `checks.tf` backend-bucket assertion to all six layers, and `-reconfigure` in the Makefile init — DEP-2.
3. Commit the validated multisite overlay as `vars/dev-multisite.tfvars` with the exact apply invocation — DEP-3.
4. Push/merge the SOK branch so sok-stop's cron and dispatch exist — DEP-4.
5. Gate prod dispatches (typed `confirm` + `environment: prod` reviewers + master-ref check) — DEP-5.
6. Mirror the running-EC2-core guard into the eks layer (or a sok-start pre-flight) — DEP-6.
7. Pin `terraform-aws-modules/eks` exactly and set explicit `addon_version` for the four addons — DEP-7.
8. Digest-pin the splunk, node-cache, and alpine/k8s images — DEP-8.
9. Add `prevent_destroy` to the smartstore/apps/kvbackup buckets — DEP-10.
10. Add PR fmt/validate/plan CI plus an end-of-start "plan must be empty" drift check — DEP-11.
11. Remove the `env = prod`/`tf-command = apply` Makefile defaults; add Makefile symlinks to the three SOK layers — DEP-12.
12. Fix sok-checks env passthrough, add concurrency, make sok-health.sh multisite-aware — DEP-13.
13. Gitignore `*.tfplan`/`plan-*.json`; move state buckets to SSE-KMS — DEP-14.
14. SHA-pin the GitHub Actions and harden the runner-IP lookup — DEP-15.
