# SOK implementation review

A four-lens review of the Splunk Operator for Kubernetes build, **security, operations, deployment/IaC, and non-functional**, first run July 2026 after the dev multisite validation (RF/SF met, SmartStore SSE-KMS, KV backup/restore), and reviewed on `master` after that branch merged. A prod build-out test has since run (see [runbook](../kubernetes-sok-runbook.md)). Each lens was an independent deep pass; the Critical and top-High findings were re-verified against the code and live AWS before publishing.

!!! success "Remediation status"
    Most findings have since been actioned, both Criticals (OPS-1, OPS-2) are **DONE**, along with ~20 others via the merged SOK branch plus a stream of finding-referenced commits. **Exact tally: DONE 22 · PARTIAL 20 · OPEN 9.** Each finding below now carries a status marker (**✅ DONE** / **◐ PARTIAL** / **○ OPEN**) with evidence. The at-a-glance table below counts *original* findings; the remaining code-change work is collected in [Remaining actions](#remaining-actions-code-changes-for-the-owner).

## At a glance (original findings, as first published)

| Dimension | Critical | High | Medium | Low | Total |
|---|--:|--:|--:|--:|--:|
| [Security](security.md) | – | 2 | 3 | 3 | 8 |
| [Operations](operations.md) | 2 | 3 | 7 | 3 | 15 |
| [Deployment / IaC](deployment.md) | – | 3 | 10 | 2 | 15 |
| [Non-functional](non-functional.md) | – | 5 | 4 | 4 | 13 |
| **Total** | **2** | **13** | **24** | **12** | **51** |

## Verdict

The implementation is genuinely well-engineered, IRSA everywhere with no static keys, a correct SmartStore SSE-KMS data path over a free gateway endpoint, and real Splunk-on-Kubernetes scar tissue baked in (THP/ulimit tuning, the node-local DNS cache, deliberate probe budgets, `WaitForFirstConsumer`, hand-built PDBs). None of the findings is a design flaw.

What they *are* is the gap between **"validated in dev"** and **"safe to run always-on in prod."** Two classes dominate: (1) the operator tooling and lifecycle automation are hardwired to the dev single-site shape and largely not yet live; and (2) a set of security and non-functional items must be closed before the prod cutover. Everything here is closeable with the effort ratings in each detail page (mostly **S**).

## What was verified

The two Criticals and the top Highs were re-checked against the actual code / live AWS, all confirmed:

- **OPS-1**, the stop-path roll selector `splunk-idxc-indexer` genuinely does not match the multisite pod labels `splunk-idxc-site1-indexer` / `-site2-indexer` (`pdb.tf:27` vs `:44`).
- **OPS-2**, `sok-health.sh` is piped through `| tee` with no `shell: bash`, so the check step's exit code is always `tee`'s zero.
- **SEC-1**, `secrets.tf:21,25` read `/monitoring/splunk/password` and `/splunk/pass4SymmKey` with no env in the path; both are prod-tagged.
- **SEC-2**, the CI role trusts `repo:livehybrid/aws-splunk-cluster:*` (any ref) and holds `PowerUserAccess` + `iam:CreateRole`/`PassRole`.
- **NFR-1**, one unconditional `resources` local (Burstable), despite the "Prod goes Guaranteed" comment.
- **DEP-1 / DEP-10 / SEC-4**, no state locking; `prevent_destroy` on the KMS key only; no bucket versioning.

**One stale claim was corrected (now itself actioned):** the KV backup/restore path *was* validated end-to-end (backup → S3 SSE-KMS → restore into the KV-store captain). The `⚠ NOT yet validated` comments have since been **removed** from `kvbackup.tf` and `sok-kvstore-backup.sh`, the *mechanism* is fine; the residual gaps are the 6h RPO, no drill cadence, and dev's Standalone having no backup.

## Cross-cutting themes

The same root causes surface across lenses, fixing each once closes several findings:

1. **Single-shape tooling.** ✅ **RESOLVED.** The stop-path roll (OPS-1), health checks (OPS-6, DEP-13), and `make kexec` were all made shape-agnostic (label-selector CR discovery). Both the stop-path no-op and the tooling false-fails are closed.
2. **Automation is now live on master.** ✅ **RESOLVED.** The branch merged to `origin/master`, so the nightly cron and dispatch exist server-side (OPS-3, DEP-4), and the validated multisite shape is committed at `_shared/vars/overlays/dev-multisite.tfvars` (OPS-9, DEP-3). Residual: confirm the first scheduled `sok-stop` fired.
3. **Dev inside the prod VPC with prod secrets** (SEC-1, SEC-5). ◐ **PARTLY CLOSED.** Dev secrets are now env-scoped (`/dev/splunk/*`) and default-deny NetworkPolicies are in place (SEC-5 DONE); the prod SG tightening and dev-own-VPC/private-subnets remain OPEN (SEC-1 partial).
4. **Supply-chain & version drift** (DEP-7, DEP-8, SEC-6, DEP-9). ◐ **MOSTLY CLOSED.** EKS module pinned exactly (21.24.0), addons carry explicit versions (DEP-7 DONE), splunk + alpine/k8s images digest-pinned (SEC-6/DEP-8 partial, `nodelocaldns` still tag-only), TF pinned 1.11.1 on SOK+CI (DEP-9 partial, EC2 workflows still 1.10.5).
5. **The EKS 1.34 cost cliff** (NFR-4, OPS-8). ✅ **DONE (documented + owned).** Runbook now owns the 1.34→1.35 path, the 2026-12-02 cliff, a 2026-11-01 go/no-go, gated on SOK release. The upgrade execution itself is future work.
6. **Prod-shape correctness gaps** (NFR-1 Guaranteed QoS, NFR-3 AZ SPOF, NFR-5 subnet IP exhaustion). ◐ **PARTLY CLOSED.** CNI IP-target config added (NFR-5 DONE), Guaranteed-QoS plumbing + SHC zone spread added (NFR-1/NFR-3 partial, prod tfvars still Burstable / no general-c, deliberately for the workload-free build-out).
7. **State & data durability** (DEP-1 no locking, SEC-3/DEP-14 prod secrets in an unhardened dev state bucket, SEC-4/DEP-10 no bucket versioning or `prevent_destroy`). ◐ **PARTLY CLOSED.** State locking added (`use_lockfile`, DEP-1 DONE); versioning + `prevent_destroy` on smartstore + kvbackup (SEC-4/DEP-10 partial, the **apps** bucket was missed); dev state bucket still SSE-S3 (SEC-3/DEP-14 partial/open).

## Priority action plan

### P0, do now (correctness bugs, small effort), ✅ ALL DONE

- ✅ **[OPS-2] Restore health-check integrity.** DONE, `shell: bash` added (sok-checks.yml:83) and `workflow_run` env recovered from the START run's `display_title`.
- ✅ **[OPS-1] Fix the nightly-stop data-loss no-op.** DONE, shape-agnostic `app.kubernetes.io/name=indexer` selector, REST index enumeration, graceful `splunk offline` per peer, prod confirm gate. (Upload-queue drain is a bounded `sleep 60`, acknowledged as the supervised prod/K7 step.)
- ✅ **[OPS-3 / DEP-4] Push & merge the branch.** DONE, sok-start/stop/checks on `origin/master`; crons active. *Residual: verify the first scheduled sok-stop fired.*
- ✅ **[OPS-15] Delete `snapshot.json`.** DONE, file absent from the repo.

### P1, before the prod cutover, mostly actioned

**Security:** ◐ env-scope the dev secrets (SEC-1, partial, secrets done, prod SGs open); ◐ scope the CI OIDC trust + drop PowerUser (SEC-2, partial, trust scoped to master, PowerUser remains); ✅ default-deny NetworkPolicies (SEC-5) / ◐ tighten prod SGs (SEC-1, open); ◐ harden the state buckets (SEC-3, DEP-14, still SSE-S3); ◐ bucket versioning + `prevent_destroy` (SEC-4, DEP-10, done for smartstore+kvbackup, **apps bucket missed**); ◐ digest-pin images (SEC-6, DEP-8, splunk+alpine done, nodelocaldns open).

**Non-functional / operations:** ◐ Guaranteed QoS in prod (NFR-1, plumbing done, prod tfvars still Burstable); ○ reassess node class / add credit alarms (NFR-2, open); ◐ SHC AZ-spread + ✅ document the CM-AZ "2a-loss = search outage" DR posture (NFR-3/OPS-14); ✅ CNI IP-target config (NFR-5); ✅ own the EKS 1.34→1.35 upgrade + runbook (NFR-4, OPS-8); ✅ harden KV backup, captain-aware, alerting, stale comments removed (OPS-5) / ◐ dev decision + drill cadence (NFR-8); ✅ add failure alerting + watchdog (OPS-4); ✅ shape-aware `sok-health`/`kexec` + SHC checks (OPS-6, DEP-13); ✅ day-2 rebuild/restore runbook + ✅ restore exit-code masking fix (OPS-7); ✅ port the cold-boot RF/SF remedy script (OPS-10, ◐ not yet wired into checks).

### P2, hardening & hygiene, mostly actioned

✅ State locking (DEP-1) + ◐ Terraform 1.11.1 (DEP-9, EC2 workflows still 1.10.5); ◐ backend-env guard (DEP-2, workspace assert done, bucket assert open) + ◐ Makefile defaults (DEP-12, env=prod removed, still defaults apply, SOK layers no symlink); ✅ commit the multisite overlay (DEP-3, OPS-9); ✅ mirror the exclusivity guard into the eks layer (DEP-6); ✅ pin module/addon versions (DEP-7); ✅ PR fmt/validate/plan CI + drift check (DEP-11); ◐ prod-dispatch confirmation gate (DEP-5, typed confirm done, no required reviewers); ◐ stop-path timeouts + lock-timeout + fail-on-residual-volumes (OPS-12, done except job `timeout-minutes`); ✅ deterministic app tarballs (OPS-11); ✅ PVC right-sizing plumbing (NFR-6, per-role storage vars); ✅ restate the cost section at the EBS-inclusive ~$750/mo (NFR-9).

## Remaining actions (code changes for the owner)

These are the still-**OPEN** code-change items (terraform / scripts / workflows). Per the docs-only remit of this pass they are flagged, not fixed, and need explicit go-ahead:

1. **SEC-7**, `sok-checks` never reverts the runner-IP `/32` it appends to the EKS `publicAccessCidrs` (`sok-checks.yml:75`); add an `always()` revert step.
2. **SEC-8**, `trusted_cidrs` default is still `["0.0.0.0/0"]` (`_shared/variables.tf:35`); force an explicit value or default `[]` with validation.
3. **OPS-13**, `MonitoringConsole` is still a fatal health check (`sok-health.sh:51,55`); now that OPS-2 makes checks able to fail, every run reds on the deferred MC. Downgrade to a warning.
4. **DEP-14**, `*.tfplan`/`plan-*.json` not gitignored; state buckets still SSE-S3 not SSE-KMS.
5. **DEP-15**, GitHub Actions are tag-pinned not SHA-pinned; the runner-IP lookup has no regex/fallback.
6. **NFR-2**, prod node groups are build-out-test `t3.large` with no `credit_specification`/CPU-credit alarm; the m6a-vs-t3-vs-alarm always-on decision is still pending.
7. **NFR-7**, indexer SmartStore cache is still 200Gi with no eviction/hotlist tuning.
8. **NFR-10**, `local.sites` is hardcoded, not derived from `var.available_sites` (Low, non-blocking).

**Notable PARTIALs still carrying code residuals:**

- **SEC-1 / SEC-2** (highest-severity, only partly closed): SEC-1's prod SG rules (HF `9997-9998` from `0.0.0.0/0`, HF `8088` / LM `8089` open to the VPC CIDR) are untouched; SEC-2 still carries `PowerUserAccess` + `iam:CreateRole`/`PassRole` with no permissions boundary. Trust-scoping and NetworkPolicies are the mitigations in place.
- **SEC-4 / DEP-10**, the **apps** bucket was missed for both `prevent_destroy` and versioning (smartstore + kvbackup got both).
- **DEP-9**, the EC2 `splunk-start`/`splunk-stop` workflows still pin Terraform `1.10.5` against a `1.11.1` estate.
- **OPS-14**, the HEC token still regenerates each rebuild (`random_uuid`, not persisted to Secrets Manager); breaks external senders post-cutover.
- **DEP-13**, no `concurrency:` key on `sok-checks` (can race the 21:30 stop).
- **OPS-10**, `sok-rf-remediate.sh` exists but is not yet wired into `sok-checks.yml` between retries.

## Accepted risks (excluded from findings)

Nightly full destroy of dev (deliberate cost guard); tiny burstable dev sizing; the deferred MonitoringConsole distributed-search auth issue; unsigned git commits.

## Strengths worth preserving

IRSA with per-role least-privilege and no static keys; SmartStore SSE-KMS over a free S3 gateway endpoint; secure EKS-module defaults left intact (secrets envelope-encryption, IMDSv2 hop-limit 1, KMS rotation); the origin:2/total:3 data-safety topology; thoughtful destroy ordering (PVC-before-CSI, EBS-reclaim wait, residual-cost hard-fail); and unusually deep design docs whose own caveat register predicted several of these findings.

---

*Each follow-up item is tracked as a task in the project backlog. The four detail pages carry the full evidence (`file:line`), impact scenarios, recommendations, and effort ratings.*
