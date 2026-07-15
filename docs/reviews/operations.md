# Operations review — SOK implementation

!!! info "Part of the [full SOK review](index.md)"
    July 2026 · **15 findings** — 2 Critical, 3 High, 7 Medium, 3 Low. Both Critical findings (OPS-1 stop-path no-op, OPS-2 always-green checks) re-verified against the code. See the [review index](index.md) for the prioritised remediation plan.

!!! success "Remediation status"
    **DONE 8 · PARTIAL 5 · OPEN 2.** Both Criticals closed. Per-finding markers below. Open code items: OPS-13. Partial residuals to note: OPS-7, OPS-10, OPS-12, OPS-14.

Reviewed: sok-start/stop/checks workflows, `terraform/layers/sok/*` + `eks/*` + `sok-foundation/*`, SOK scripts, shared tfvars, plan/ops docs. Originally verified against branch `sok/multisite-dev-validation` (now merged to master); a prod build-out test has since run.

## Findings

### [OPS-1] Nightly stop's hot-bucket roll silently no-ops on multisite, and never verifies drain
- **Severity**: Critical (latent — dev single-site works today; bites on any multisite stop, including the prod cutover path)
- **Status**: ✅ **DONE** — `sok-stop.yml:110` uses the shape-agnostic `-l app.kubernetes.io/name=indexer` selector (matches single-site AND site1/site2); indexes are enumerated via REST `:117-119`; a graceful `splunk offline` runs per peer `:138-143`; a prod confirm gate is added `:54-60`. The precise upload-queue poll was replaced by a bounded `sleep 60`, acknowledged as the supervised prod/K7 step rather than an exact queue drain.
- **Evidence**:
  - `.github/workflows/sok-stop.yml:91` selects pods with `-l app.kubernetes.io/instance=splunk-idxc-indexer` — the label of the **single-site** CR only (`crs.tf:205` names it `idxc`; the operator's instance label is `splunk-<cr>-indexer`).
  - Multisite creates CRs `idxc-site1`/`idxc-site2` (`terraform/layers/sok/crs.tf:234`, `count = var.multisite ? 0 : 1` at crs.tf:201 means `idxc` **doesn't exist** in multisite). The repo's own PDBs confirm the multisite label is `splunk-idxc-<site>-indexer` (`terraform/layers/sok/pdb.tf:44`).
  - With `2>/dev/null` on the pod list and `|| true` on the exec (sok-stop.yml:91–95), an empty match produces zero output, zero errors — the roll step "succeeds" having rolled nothing.
  - Even when it matches, it rolls only `main _internal _audit` (line 92) and then `sleep 30` (line 97) — no cache-manager upload-queue check. The plan explicitly required enumerating indexes via REST and verifying upload queues empty before teardown (`docs/kubernetes-sok-plan.md:564–571`), and the caveat register predicted exactly this failure: "2am data-loss guard silently no-ops" (plan line 712).
  - The workflow offers `env: [dev, prod]` with no approval gate (sok-stop.yml:27), so post-cutover this same destroy is prod's manual stop path.
- **Impact**: On a multisite stop, no hot buckets are rolled; namespace destruction then deletes the PVCs (reclaimPolicy Delete, `eks/storage.tf:25`) with pods getting only the default ~30s SIGTERM grace (v4 CRs can't set terminationGracePeriodSeconds, `pdb.tf:10`). Everything ingested since the last natural roll — in every index, on every peer — is unrecoverable. In dev this is accepted; run the identical workflow against a cut-over prod and it is real data loss. Even in dev, an upload exceeding the 30s sleep is killed mid-multipart.
- **Recommendation**: Select indexer pods shape-agnostically (e.g. `app.kubernetes.io/name=indexer`, verified live, or iterate `kubectl get indexercluster -o name`); enumerate indexes via `/services/data/indexes`; replace `sleep 30` with a poll of cache-manager upload queues; add a GitHub environment protection rule for `env=prod`.
- **Effort**: S

### [OPS-2] SOK CHECKS can never fail — the health verdict is piped through `tee` without pipefail
- **Severity**: Critical
- **Status**: ✅ **DONE** — `shell: bash` added to the health step (`sok-checks.yml:83`) restoring pipefail; the `workflow_run` env is recovered from the START run's `display_title` (Resolve-target-env step `:38-49`), so a prod START completion checks prod, not dev.
- **Evidence**: `.github/workflows/sok-checks.yml:70`: `if ./scripts/sok-health.sh "$TARGET_ENV" | tee /tmp/sok-health.log; then` — the file contains **no** `shell:` directive anywhere, so GitHub runs it with `bash -e {0}` (no pipefail); the `if` tests `tee`'s exit code, which is always 0. Attempt 1 always "passes", prints "healthy", and exits 0. The sibling EC2 workflow documents this exact trap and fixed it: `.github/workflows/splunk-checks.yml:74` — `shell: bash # explicit => pipefail on; default shell would let '| tee' mask failures`.
- Additionally, the auto-trigger checks the wrong environment: `workflow_run` events carry no `inputs`, and `TARGET_ENV: ${{ inputs.env || 'dev' }}` (sok-checks.yml:29) means a **prod** SOK START completion triggers checks against **dev**.
- **Impact**: The only automated post-start verification is a rubber stamp — a cluster that came up with RF/SF unmet, KV store down, or licence missing shows a green check run (the failure text is visible only if a human reads the step summary). The 12×120s retry envelope is decorative. Post-cutover, prod starts would additionally be "verified" by probing dev.
- **Recommendation**: Add `shell: bash` to the step (one line, mirroring splunk-checks.yml); derive `TARGET_ENV` for `workflow_run` events from the triggering run (or drop auto-trigger for prod).
- **Effort**: S

### [OPS-3] None of the SOK automation is live: workflows absent from the default branch, 23 commits unpushed
- **Severity**: High
- **Status**: ✅ **DONE** — sok-start/stop/checks are on `origin/master` (branch merged via PR #3); the cron and dispatch surface are active. *Residual: confirm the first scheduled sok-stop actually fired.*
- **Evidence**: `git show origin/master:.github/workflows/sok-stop.yml` → file does not exist (same for base remote). `git log origin/master..HEAD` = 23 commits, and `sok/multisite-dev-validation` exists on no remote. Scheduled (`cron: "30 21 * * *"`, sok-stop.yml:31) and `workflow_run` triggers only fire from the default branch; `workflow_dispatch` isn't even listable for workflows absent there.
- **Impact**: The nightly cost guard, on-demand start, and post-start checks do not exist on GitHub — the "destroyed nightly" behaviour currently depends on someone running things by hand. A dev cluster left up costs ~$6.5/day silently. All multisite-validation fixes (node-local DNS, peer site config, KV captain detection) live on one laptop; losing it loses the validated implementation.
- **Recommendation**: Push the branch immediately; merge to master (after OPS-1/OPS-2 fixes) to activate the cron and dispatch surface.
- **Effort**: S

### [OPS-4] No monitoring, alerting, or log shipping anywhere in the SOK path
- **Severity**: High
- **Status**: ✅ **DONE** — `if: failure()` Slack notify on all three workflows (sok-start/stop/checks); an in-cluster watchdog (`sok/alerting.tf`, 10-min CronJob) catches CRs-not-Ready, crash-loops and failed Jobs. (A full metrics story remains a future decision.)
- **Evidence**: Zero matches for slack/sns/notify/alert in any sok-* workflow (vs the EC2 estate's `splunk-ops-alert` SNS → Slack + Telegram and EventBridge→HEC, `docs/operations.md:88–95`). No metrics stack in the eks layer (addons are coredns/kube-proxy/vpc-cni/ebs-csi only, `eks/eks.tf:48–57`); node-local-dns exposes Prometheus ports (`nodelocaldns.tf:52,63,72`) that nothing scrapes. The kvbackup CronJob keeps 3 failed jobs of history (`kvbackup.tf:149`) but alerts no one. No `timeout-minutes` on any job; no failure-notification step; sok-checks has no cron for periodic in-day health.
- **Impact**: RF/SF degradation, a wedged CR, a failed 21:30 destroy (cluster billing all night, possibly a stuck TF state lock making every subsequent nightly run fail too), or a month of failed KV backups are all invisible until a human runs `make sok-health` or reads the Actions tab. Splunk's own `_internal` history is deleted nightly with the PVCs; post-cutover prod's only copy of its platform logs would live inside the platform.
- **Recommendation**: Minimum viable: `if: failure()` notification step (reuse the existing SNS topic or Slack webhook) on sok-stop/start/checks; a CloudWatch alarm (or in-cluster kube-state alert) on CronJob failure; decide a metrics story (Container Insights or kube-prometheus-stack) before cutover.
- **Effort**: M

### [OPS-5] KV backup: dev's default shape has no backup at all, and the mechanism fails silently with a 30-day age-out
- **Severity**: High
- **Status**: ✅ **DONE** — the backup now auto-detects the KV-store captain (`sok-kvstore-backup.sh:28-39`), captures the exit code (`:47-55`), and the stale "NOT validated" comment is removed; the dev-Standalone-unprotected contract is stated in `kvbackup.tf:3-16`. (Job-failure alerting is covered by OPS-4's watchdog. Extending backup to dev's Standalone is by-design deferred, not done.)
- **Evidence**: Every kvbackup resource is gated `count = var.enable_shc ? 1 : 0` (`terraform/layers/sok/kvbackup.tf:20,47,66,79,90,128,140`) and dev sets `enable_shc = false` (`terraform/layers/_shared/vars/dev.tfvars:81`) — so the currently-running environment has **no CronJob, no IRSA role, nothing**; the Standalone SH's KV store (lookups, dashboards, app state) is wiped every 21:30 with no copy. This is documented as deliberate (`kvbackup.tf:4`), but note the gate is search-tier shape, not data value. Backups target the hardcoded pod `splunk-shc-search-head-0` (`scripts/sok-kvstore-backup.sh:23`) — not the KV captain the restore path had to learn about (`sok-kvstore-restore.sh:9–14`) — and fail outright if member 0 is the one that's down. The bucket lifecycle expires backups at 30 days (`sok-foundation/kvbackup.tf:63–70`). Both script and TF headers still carry "⚠ NOT yet validated" warnings (`sok-kvstore-backup.sh:13–15`, `kvbackup.tf:14–16`) despite the validation.
- **Impact**: With no failure alerting (OPS-4), a CronJob broken for 30 days (image pull failure, RBAC drift, member-0 outage) silently ages out the last good backup — the classic dead-backup discovery at restore time. Anyone using dev for app development loses KV content nightly and nothing in dev.tfvars or the run summary says so.
- **Recommendation**: Reuse the restore script's captain detection in the backup; alert on Job failure; either extend the CronJob to dev's Standalone or state the "dev KV is unprotected" contract in dev.tfvars and the start-run summary; delete the stale not-validated warnings (recording what was validated instead).
- **Effort**: M

### [OPS-6] All operator tooling is hardwired to the dev single-site shape — a healthy prod cluster fails health checks
- **Severity**: Medium (High at cutover)
- **Status**: ✅ **DONE** — `sok-health.sh` is fully shape-agnostic (iterates existing CRs, role-label discovery, SHC captain + KV checks); `Makefile:249` `kexec` uses label selectors with an SHC fallback.
- **Evidence**: `scripts/sok-health.sh:42` iterates `indexercluster/idxc standalone/sh …` — in multisite there is no `idxc` and no `sh`, so two red ✗ per run against a healthy prod cluster, while the SHC/deployer get no checks at all; the KV check targets only `splunk-sh-standalone` (line 59). `Makefile:245–246` kexec maps `indexer→splunk-idxc-indexer`, `sh→splunk-sh-standalone` (no site variants, no SHC role). Same root cause as OPS-1's selector.
- **Impact**: At prod shape, `make sok-health`/SOK CHECKS false-fail permanently (once OPS-2 makes failures count), and there is no way to shell into a prod indexer or SHC member via the documented `make kexec`. Operators lose their entire day-2 toolset exactly when the shape changes.
- **Recommendation**: Make CR/pod discovery dynamic (`kubectl get indexercluster -o name`; branch Standalone-vs-SHC on what exists); add SHC checks (captaincy, KV member health) mirroring `cluster-health.sh`; extend kexec with `site=`/`shc` roles.
- **Effort**: M

### [OPS-7] Prod rebuild/restore runbook is incomplete: KV restore isn't wired into start, and day-2 procedures are undocumented
- **Severity**: Medium
- **Status**: ◐ **PARTIAL** — restore-script exit-code masking fixed (`sok-kvstore-restore.sh:58-67`), captain detection guarded, and `docs/kubernetes-sok-runbook.md` now covers rebuild/restore/password/HEC/day-2 (DONE). Optional KV-restore-into-`sok-start` wiring is **not** done (allowed as optional).
- **Evidence**: `kvbackup.tf:4–5` says restore happens "manual / start-workflow", but `sok-start.yml` contains no restore step and `docs/operations.md:62–70`'s SOK table omits the kvstore targets entirely (they exist only in `Makefile:261–265`). No SOK entry covers: retrieving the admin password or port-forwarding the UI (only the `hints` terraform output, `sok/outputs.tf:9–15`), rolling a single peer safely, scaling an indexer site (plus the #1646 one-unready-pod-blocks-scaling trap, plan line 696), admin password rotation (EC2 has `make rotate-admin`; the operator's secret model differs), or the wedged-CR recovery ladder (exists only inside the plan, K5.4; `docs/troubleshooting.md` has zero SOK content). Also `sok-kvstore-restore.sh:56–58` masks the restore exit code (`… | grep -viE … || true` — under pipefail the `|| true` swallows a failed `splunk restore kvstore`), and at line 39 a captain-detection failure under `set -e` kills the script before its own friendly error at line 40.
- **Impact**: A 3am prod rebuild by someone other than the author stalls on undocumented steps; a failed KV restore can print an error yet exit 0, leaving the operator believing state was re-seated.
- **Recommendation**: Add a "rebuild prod SOK" runbook section (start → verify → restore KV → verify captain); optionally an opt-in restore step in sok-start; propagate the restore exit code and post-check `show kvstore-status`.
- **Effort**: M

### [OPS-8] No owned upgrade path: EKS 1.34 has a dated cost cliff, and operator/Splunk/addon versions are absorbed implicitly
- **Severity**: Medium
- **Status**: ✅ **DONE** — the runbook's upgrade section documents the 1.34→1.35 path, the 2026-12-02 cliff, a 2026-11-01 calendar go/no-go, and gating on the SOK release. (Addon/AMI version pinning is tracked under DEP-7/DEP-8.)
- **Evidence**: `variables.tf:359` documents that EKS 1.34 exits standard support **2026-12-02** (then ~6x control-plane billing) and that SOK 3.1.0's ceiling is 1.34 — but no doc, issue, or workflow owns the bump. CRD/chart upgrades exist only as a code comment (`operator.tf:33`, `variables.tf:415`); Splunk image upgrade order (LM→CM→SH→peers; no downgrades — plan line 697) is undocumented. EKS addons carry no version pins (`eks.tf:48–57`), node AMI is unpinned `AL2023_x86_64_STANDARD` (`eks.tf:61`), and the kvbackup image is a Docker Hub community tag (`kvbackup.tf:161`) subject to unauthenticated pull limits — nightly rebuilds silently absorb whatever is latest.
- **Impact**: Five months from now the parked-or-live cluster cost jumps 6x unless someone remembered; the first prod Splunk upgrade will be improvised on a one-way (no-downgrade) path.
- **Recommendation**: Write the upgrade runbook (EKS version, node AMI, operator+CRDs, Splunk image, in that coupling order); pin addon/AMI/image versions for prod; calendar the 1.34 deadline against SOK release tracking.
- **Effort**: M

### [OPS-9] The validated multisite shape is not reproducible from the repo
- **Severity**: Medium
- **Status**: ✅ **DONE** — `_shared/vars/overlays/dev-multisite.tfvars` is committed; `sok-start.yml:27-30,61-63` adds an `overlay` dispatch input that appends the second `-var-file`.
- **Evidence**: The dev multisite validation (2 IndexerCluster CRs + SHC 3 + kvbackup) ran from an overlay tfvars in a job tmp dir; no `*multisite*` tfvars exists anywhere in the repo (verified by find), committed `dev.tfvars` is single-site/`enable_shc=false`, and `sok-start.yml:77–86` can only apply `vars/$TARGET_ENV.tfvars` (no overlay input).
- **Impact**: The exact shape that passed S0b/RF-SF/KV validation cannot be re-created by CI or another operator — re-validation, regression testing of the multisite fixes, or a cutover rehearsal requires reconstructing variables from memory.
- **Recommendation**: Commit the overlay (e.g. `_shared/vars/dev-multisite.tfvars`) and add an optional `overlay` input to sok-start/stop that appends a second `-var-file`.
- **Effort**: S

### [OPS-10] The SmartStore cold-boot RF/SF stall auto-remediation was never ported, but SOK cold-boots every day
- **Severity**: Medium
- **Status**: ◐ **PARTIAL** — `scripts/sok-rf-remediate.sh` exists (ported, wired via `make sok-rf-remediate`). **Not yet wired into `sok-checks.yml`** between retries — checks still only sleep/retry, so the auto-heal is manual for now.
- **Evidence**: Plan K5.2 requires porting `rf-remediate.sh` ("same fixup-signature detection; remedy = rolling-restart via exec on the CM pod", `docs/kubernetes-sok-plan.md:554–556`); the EC2 checks workflow calls it between retries (`splunk-checks.yml:88`), and `docs/operations.md:78–86` documents the stall signature as expected behaviour on cold boots against a populated bucket. `sok-checks.yml` only sleeps and retries; no SOK equivalent script exists.
- **Impact**: The morning start is precisely a cold boot over legacy buckets — when fixups stall with "Missing enough suitable candidates", SOK checks (once they can fail, OPS-2) burn 24 minutes and go red where EC2 would have self-healed; a human must know to exec a rolling restart.
- **Recommendation**: Port the signature detection + `splunk rolling-restart cluster-peers` remedy into sok-health or between check retries.
- **Effort**: S

### [OPS-11] App deploys are never no-ops: non-reproducible tarballs re-trigger every app install (and cluster bundle pushes)
- **Severity**: Medium
- **Status**: ✅ **DONE** — `package-apps.sh:71-83` produces deterministic archives (`--owner=0 --group=0 --numeric-owner`, mtime-pinned staged copy, `gzip -n`), so unchanged content yields identical bytes/Etags.
- **Evidence**: `scripts/package-apps.sh:36–42,65` — each run fresh-clones into `mktemp` and `tar -czf`s; member mtimes are checkout-time, so archive bytes (and S3 Etags) differ every run even with zero content change. App Framework change detection is Etag-by-filename (script header, lines 18–19), so all apps in scope are re-downloaded/re-installed; cluster-scope re-installs flow through a CM bundle push to all peers.
- **Impact**: A routine `make sok-deploy-apps` with no actual changes can roll indexer peers; deploys are indistinguishable from changes in audit/behavioural terms.
- **Recommendation**: Deterministic archives: `tar --sort=name --owner=0 --group=0 --numeric-owner --mtime=@0` piped to `gzip -n`; optionally skip upload when the built archive hash matches S3.
- **Effort**: S

### [OPS-12] Stop-path failure handling: no timeouts, no lock strategy, and the EBS-reclaim wait falls through
- **Severity**: Medium
- **Status**: ◐ **PARTIAL** — `-lock-timeout=5m` on all sok/eks tf calls, `timeout` on execs, a hard-fail on residual volumes (`sok-stop.yml:163-166`), and an eks-destroy retry (`:173-175`) are all in. **Residual: no `timeout-minutes` on the job itself.**
- **Evidence**: `sok-stop.yml:106–113` polls for zero cluster-tagged volumes for at most 30×10s but does not fail on timeout — it proceeds to destroy the cluster anyway, which orphans any still-reclaiming volumes (the exact scenario the header at lines 13–15 warns bills nightly); the final verify (lines 124–135) detects and reddens but nothing remediates, and no runbook covers manual `aws ec2 delete-volume`. The sok destroy has no retry (only eks does, lines 120–122); no job has `timeout-minutes`; a runner killed mid-destroy leaves an S3 state lock that makes every subsequent nightly attempt fail (compounded by OPS-4's absent alerting). The best-effort allowlist step (`|| true` at line 86) means a cluster stuck in UPDATING quietly skips runner allowlisting and the destroy then fails on API reachability.
- **Impact**: A halfway-failed 21:30 destroy leaves a full cluster (or orphaned volumes) billing indefinitely with a red run nobody is notified about, and can self-perpetuate via the stale lock.
- **Recommendation**: `timeout-minutes` on the job; `-lock-timeout=5m`; fail the workflow if volumes remain before eks destroy (and document orphan-volume cleanup); retry the sok destroy once like eks.
- **Effort**: S

### [OPS-13] Known-broken MonitoringConsole is a fatal health check
- **Severity**: Low (**raised in practice** — now that OPS-2 makes checks able to fail, this reds every run)
- **Status**: ○ **OPEN** — `sok-health.sh:51,55` still lists `monitoringconsole` in the fatal CR-phase loop with no warn/non-fatal downgrade. With OPS-2 now live, every check run reds on the deferred MC, so this is higher priority than the original Low.
- **Evidence**: `sok-health.sh:42–45` treats `monitoringconsole/mc` phase != Ready as a failure; the MC distributed-search auth issue is known/deferred (`docs/kubernetes-sok-plan.md:46–50`).
- **Impact**: Once OPS-2 makes failures count, every check run is red while the MC issue stays deferred — either checks get ignored (alert fatigue) or the MC gets un-deferred under pressure.
- **Recommendation**: Downgrade MC to a warning (non-fatal) until the auth issue is fixed, with a comment linking the deferral.
- **Effort**: S

### [OPS-14] Prod-shape latent traps: HEC token rotates on every rebuild; CM is hard-pinned to one AZ; rollback ordering can wedge on the exclusivity guard
- **Severity**: Low (prod-cutover era)
- **Status**: ◐ **PARTIAL** — the CM-AZ failure mode and the mandatory rollback order are documented in the runbook (DONE). **Residual: the HEC token is still `random_uuid` (`secrets.tf:34,47`), not persisted to Secrets Manager — it still rotates on every rebuild.**
- **Evidence**: `secrets.tf:32,45` — `random_uuid.hec_token` lives in the sok layer's state, which stop **destroys**, so any prod stop/start mints a new HEC token (fine in dev per the comment; breaks external senders post-cutover). `crs.tf:143` pins the CM with requiredDuringScheduling to eu-west-2a — a 2a outage leaves the CM unschedulable anywhere (no bucket fixups/bundle pushes until the AZ returns). `main.tf:36–56`'s EC2-running postcondition is evaluated on data-source reads, so a panicked rollback that starts EC2 *before* destroying the sok layer likely blocks the sok destroy itself (the plan's K7.3.6 order — destroy sok first — is the only safe path and should be stated as such).
- **Recommendation**: Persist the HEC token (Secrets Manager, like the other secrets) before cutover; document the CM-AZ failure mode and the mandatory rollback order in the cutover runbook.
- **Effort**: S

### [OPS-15] Untracked `snapshot.json` at repo root contains device keys
- **Severity**: Low
- **Status**: ✅ **DONE** — the file is absent from the repo.
- **Evidence**: `snapshot.json` — an unrelated IoT device dump including `productKey`/token fields, sitting untracked in the reviewed repo.
- **Recommendation**: Delete (or move out and .gitignore) before it gets committed by accident.
- **Effort**: S

## Strengths (brief)
- The destroy ordering is genuinely well-engineered: PVC deletion while the CSI driver exists, an EBS-reclaim wait, eks retry, and a residual-cost verify that hard-fails (`sok-stop.yml` header + steps) — plus `prevent_destroy` on the data KMS key and lifecycle rules (30d kvbackup expiry, multipart abort) in sok-foundation.
- Probe overrides are deliberate and documented against bucket-corruption risk (~20-min startup budget, `crs.tf:12–37`); PDBs are shape-aware and correctly skip the 1-replica dev case (`pdb.tf:6–8`).
- No static credentials anywhere: IRSA for SmartStore, App Framework, and KV backup, with derived trust policies that survive nightly OIDC-provider recreation.
- The EC2/SOK exclusivity guard on both paths, the eks/sok layer split with concrete remote-state provider wiring, and symlinked shared tfvars (single source of truth) are all solid operational hygiene.
- Documentation depth is exceptional for a project this age — the plan's caveat register (§9) predicted several of the issues found here, including the exact stop-path failure in OPS-1.
- The silent-401 trap awareness and in-pod password handling in `sok-health.sh` show real operational scar tissue applied consistently.

## Suggested follow-up tasks (ordered)
1. Add `shell: bash` to the sok-checks health step and fix `workflow_run` env routing (OPS-2) — two lines, restores all verification.
2. Fix the stop-path roll: shape-agnostic indexer selector, REST index enumeration, upload-queue drain check, prod environment protection (OPS-1).
3. Push the branch and merge to master to activate the nightly cron and dispatch surface (OPS-3).
4. Add failure notifications (SNS/Slack) to sok-stop/start/checks and a CronJob-failure alert; add `timeout-minutes` + `-lock-timeout` and fail-on-residual-volumes to sok-stop (OPS-4, OPS-12).
5. Commit the validated multisite overlay tfvars and add an overlay input to sok-start/stop (OPS-9).
6. Make sok-health/kexec shape-aware and add SHC checks; port rf-remediate into the retry loop (OPS-6, OPS-10).
7. Harden KV backup: captain detection, failure alerting, dev-Standalone decision, delete stale "NOT validated" headers (OPS-5).
8. Write the SOK day-2 runbook: prod rebuild + KV restore, wedged-CR ladder, single-peer roll, site scale-up, password retrieval/rotation, UI access, upgrade procedure with the 2026-12-02 EKS deadline owner (OPS-7, OPS-8).
9. Make package-apps.sh archives deterministic (OPS-11).
10. Persist the HEC token to Secrets Manager and document CM-AZ and rollback-order failure modes before the cutover rehearsal (OPS-14).
11. Remove `snapshot.json` from the repo root (OPS-15).
