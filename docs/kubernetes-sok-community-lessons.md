# SOK community lessons — Gareth Anderson review

Full digest of three articles by **Gareth Anderson (SplunkTrust)** reviewed
against this implementation, with adoption status. Companion to the runbook's
"Community lessons adopted" summary; the actionable remainder is tracked as
backlog task #55, and the apps-repo half now ships from the `splunk-apps` repo.

**Sources:**

1. [SOK: lessons from our implementation, pt 1](https://medium.com/@gjanders03/splunk-operator-for-kubernetes-sok-lessons-from-our-implementation-0982774e42fc) (Jul 2024, SOK 2.2–2.5 era)
2. [SOK: lessons from our implementation, pt 2](https://medium.com/@gjanders03/splunk-operator-for-kubernetes-sok-lessons-from-our-implementation-part-2-d076715bc9cb) (Aug 2025)
3. [Splunk Lantern: SOK — Advanced operational learnings](https://lantern.splunk.com/Platform_Data_Management/Transform_Pipelines/Splunk_Operator_for_Kubernetes%3A_Advanced_operational_learnings) (formalised version of pt 2)

## Lessons vs our implementation

| Lesson | Art# | Status | Notes |
|---|---|---|---|
| Explicit requests/limits on every CR | 1 | ✅ ADOPTED (pre-existing) | Per-role knobs + Guaranteed-QoS prod knob |
| Don't co-locate CM on indexer nodes | 1 | ✅ ADOPTED | Soft podAntiAffinity on the CM (`crs.tf`) |
| Graceful `splunk offline` before pod/node kill | 1,2,3 | ✅ ADOPTED | STOP workflow per-peer offline; his #1 corrupted-SmartStore-bucket cause — corrupt buckets persist into S3 |
| SmartStore-only indexers under SOK | 1 | ✅ (design) | S3 SSE-KMS + IRSA |
| App Framework never deletes apps (GH #893) | 1 | ✅ ADOPTED | `sok-health.sh` flags orphaned apps (status `repoState=Deleted`, still on the pod); retire via a same-named `state=disabled` tombstone package |
| AppFW may not restart Standalone/CM post-deploy | 1 | 💡 could | Verify on 3.1.0; deploy tooling restarts today |
| Operator FSM can hang on stalled bundle | 1 | 💡 could | Extend watchdog to stuck-CR-phase alerting |
| 9997 is plaintext S2S | 1 | ✅ documented | Confirmed + recorded as an accepted gap (`security.md`); SSL on an alt input (9998) behind the future S2S NLB is the follow-on |
| `site0` CM unsupported; explicit site config | 1 | ✅ (pre-existing) | Per-peer `[general] site`; multisite_master CM-only |
| MC marks rescheduled indexers "new" until Apply | 1 | ✅ built, pending live test | MC `appRepo` + `mc-apps/` mapping wired (`crs.tf`); SplunkAdmins + TA-webtools vendored (`splunk-apps`); auto-Apply saved search ships — live acceptance test outstanding |
| Probe overrides (idx fT40/liveness fT30; CM fT14) | 2,3 | ✅ (pre-existing, from his Lantern article) | `crs.tf` — attribution now explicit |
| Command-based liveness `splunk status` (GH #1321, SOK 3.0+) | 2,3 | 💡 could | Truer than port-check; small CR change |
| Node-local DNS cache (9.3.3+ clustering DNS bug) | 2,3 | ✅ (pre-existing) | Also our STS/IRSA race fix |
| Spegel local image mirror | 2,3 | 💡 could | Marginal on EKS/ECR |
| Ship operator logs + K8s events + OOM into Splunk | 1,2,3 | 🔜 #53 | The SOK console collector's phase 2/3 |
| `debug_metrics=true` + per-indexer handoff searches | 2,3 | 💡 could | Perf visibility |
| `defaultsUrl` ConfigMap over inline defaults | 2,3 | 💡 could | We mix both deliberately (immutable inline vs editable mounted); pairs with the sok-apply guardrail |
| Search memory guardrails (`enable_memory_tracker` + threshold) + cgroup cache-thrash watch | 2,3 | ✅ ADOPTED | `org_search_limits` app in `splunk-apps` (`limits.conf`: `enable_memory_tracker=true`, `search_process_memory_usage_threshold=3500`), sized to pod limits |
| cgroupsv2 whole-tree OOM kill → `singleProcessOOMKill` | 2,3 | ✅ ADOPTED | kubelet NodeConfig (+ shutdownGracePeriod 2m) |
| SmartStore cache sizing (~200GB/day ⇒ >7TB) | 2,3 | 💡 could | Validate PVC knobs at cutover sizing |
| CM bundle-push S3-cred re-encrypt bug | 2,3 | N/A | Splunk 10.4 + SOK 3.1 + IRSA (no static creds) |
| Deployer resource-parity bug (GH #1307) | 2,3 | N/A | Fixed pre-3.1.0 |
| Searchable rolling restart pauses DMA | 2,3 | N/A (note) | Prod upgrade runbook note; no fix exists (idea EID-I-12) |
| Corrupt-bucket repair runbook (fsck → freeze → `_bulk_register`) | 2,3 | 💡 could | Write as ops doc — likeliest needed after any unclean shutdown |
| Usage-based rebalance / auto_data_rebalance | 2,3 | 💡 could | Modest gain at 4 indexers |
| Istio mTLS, MTU/VXLAN, WLM pools, Velero, 2× hardware econ | 1,2,3 | N/A | Mesh/on-prem/premium concerns we don't have; Terraform rebuild is our DR |

## Where the actionable pieces live

- **Adopted code**: STOP workflow (`sok-stop.yml` offline step), eks kubelet
  NodeConfig (`eks.tf`), CM anti-affinity + probe attribution (`crs.tf`) —
  commits `50c883a` + `a5e3625`.
- **Task #55** (project backlog): the #893 drift check ✅, memory guardrails ✅
  and 9997 verification ✅ are now done; MC Apply automation is built and needs
  only a live acceptance test. What is left is the 💡 could-adopt list above.
- **Apps repo**: the conf content (MC apps, `org_search_limits`) ships from the
  `splunk-apps` repo.
- **Runbook** "Community lessons adopted": the operator-facing summary.
