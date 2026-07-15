# SOK operations runbook

Day-2 operations for the Splunk Operator for Kubernetes (SOK) build
(`deployment_model = sok`). Companion to the [overview](kubernetes-sok-overview.md)
(what it is) and the [review](reviews/index.md) (what's still open). Everything
here assumes `make kubeconfig env=<env>` has pointed `kubectl` at the cluster.

## Lifecycle at a glance

| Action | Command | Notes |
|--------|---------|-------|
| Start | `SOK START` workflow (dev \| prod) | Applies foundation→eks→sok. ~8–10 min for infra + operator, ~30–45 min to a fully-healthy dev cluster (measured, NFR-13); prod is longer (SHC bootstrap, 2 IndexerCluster CRs, KV restore). |
| Stop | `SOK STOP` workflow + nightly 21:30 UTC (dev) | Rolls hot buckets, destroys sok then eks, keeps the foundation. |
| Status | `make sok-status env=<env>` | CR phases + pods. |
| Health | `make sok-health env=<env>` | RF/SF, KV, licence — shape-aware (Standalone or SHC). |
| Shell | `make kexec env=<env> role=cm\|indexer\|sh\|lm\|mc` | `sh` resolves Standalone or SHC. |
| Apps | `make sok-deploy-apps env=<env> [scope=all]` | git→S3→operator→pods. |
| KV backup | `make sok-kvstore-backup env=<env>` | Prod SHC only; also a 6h CronJob. |
| KV restore | `make sok-kvstore-restore env=<env> [archive=<name>]` | Targets the KV-store captain. |

!!! note "Verify after any start"
    `make sok-health env=<env>` must end `✓ all SOK health checks passed`. It
    discovers whatever CRs exist, so it is correct on both the dev Standalone and
    the prod multisite/SHC shape. The GitHub **SOK CHECKS** workflow runs the same
    script (with `pipefail`, so it can actually fail).

## Common day-2 tasks

### Roll apps out

```bash
make sok-deploy-apps env=prod scope=all      # or scope=cm|sh|idx|shc
```
Apps flow git → the foundation apps bucket → the operator (App Framework, IRSA) →
pods: the cluster bundle to indexers, the deployer to the SHC. Poll progress with
`make sok-status`.

### Back up / restore the KV store (prod SHC)

```bash
make sok-kvstore-backup env=prod                       # → s3://…-kvbackup-prod/kvstore-<ts>
make sok-kvstore-restore env=prod                      # latest archive
make sok-kvstore-restore env=prod archive=kvstore-20260710T…Z
```
Both auto-detect the **KV-store captain** (which is *not* necessarily the SHC
captain — different member). Restore replicates the collections out from the
captain to the other members. Override the target with `KVSTORE_POD=…`.

### Shell into a pod

```bash
make kexec env=prod role=indexer     # first indexer peer (any site)
make kexec env=prod role=sh          # SHC member (or the Standalone in dev)
```

### Send data over HEC

HEC is **enabled on every indexer at first boot** by splunk-ansible, listening
on **HTTPS :8088** with a token the operator provisions from the global secret
(`hec_token` — a fresh UUID each rebuild, by design). It is **not exposed
externally** (no NLB yet — the S2S/HEC NLB is a planned item; the external ALB
fronts only the :8000 UIs), so reach it with a port forward:

```bash
# the token (rotates on every rebuild):
kubectl get secret splunk-splunk-secret -n splunk -o jsonpath='{.data.hec_token}' | base64 -d

# reach an indexer's HEC:
kubectl port-forward -n splunk svc/splunk-idxc-indexer-service 8088:8088

# health (no auth) then send:
curl -k https://localhost:8088/services/collector/health
curl -k https://localhost:8088/services/collector/event \
  -H "Authorization: Splunk <token>" \
  -d '{"event":"hello from HEC","sourcetype":"hec:test","index":"main"}'
```

**External senders** — flip `sok_hec_external_enabled = true` (requires the
external-web flag) and HEC rides the shared ALB at
`https://<first-label>-hec.<zone>` on **:443 with the real ACM cert** (which is
also what Firehose demands). The sender's egress IP must be in
`sok_web_external_allowed_cidrs`:

```bash
curl "https://sok-dev-hec.splunk.livehybrid.com/services/collector/event" \
  -H "Authorization: Splunk <token>" \
  -d '{"event":"hello via ALB","sourcetype":"hec:test","index":"main"}'
```

**More tokens / real inputs:** the operator manages only the one global token.
Additional tokens belong in an app — `inputs.conf` with `[http://<name>]`
stanzas — shipped via `manager-apps/` in the apps repo (`make sok-deploy-apps
scope=idx`), so the CM's cluster bundle puts identical tokens on every indexer.
Ad-hoc REST-created tokens on one peer don't replicate and die with the pod.
The ALB's 7-day stickiness covers `useACK` senders (ack polls must return to
the receiving indexer).

## Config changes on a LIVE cluster (restart behaviour + guardrail)

Terraform updates Splunk CRs in place, but the operator reconciles CR changes
into **pod restarts**. Know the blast radius before applying to a live estate:

| Tier | Behaviour on CR change |
|------|------------------------|
| SHC members | **Rolling, one member at a time** (StatefulSet semantics) — quorum kept, UI stays up; in-flight searches on the rolling member die |
| Indexers (per site) | Rolling per StatefulSet; peers re-register with the CM as they return |
| CM / LM / MC / deployer | **Singletons — brief outage** (~2–4 min each); searches continue through a CM blip, bundle pushes/fixups pause |

Use the guarded apply instead of a raw terraform apply:

```bash
make sok-apply env=prod                 # plans, then REFUSES to roll live pods without a typed ROLL / CONFIRM=ROLL
make sok-apply env=prod target='kubectl_manifest.search_head_cluster[0]'   # staged rollout, one CR at a time
```

Staged order for uptime-sensitive changes (e.g. enabling external web on prod):
**SHC first** (rolling, quorum-safe) → `make sok-health` → LM → MC → **CM last**
(or in a window). A fresh/absent cluster skips the prompt — nothing is running
to disturb. Note the PDBs guard *evictions* only — they do not gate rolling
updates; the one-at-a-time property comes from the StatefulSets themselves.

## Disaster-recovery posture

!!! warning "The Cluster Manager is a single point for search"
    The CM runs as **one pod pinned to eu-west-2a** (`crs.tf`, multisite affinity).
    SmartStore data in S3 is safe regardless, and indexers keep **ingesting** if the
    CM is briefly gone, but **search coordination and the cluster bundle stop**
    until the CM pod reschedules. If the 2a nodegroup is lost, the CM cannot
    reschedule until 2a capacity returns — so **loss of AZ 2a is a search outage**,
    not just degraded capacity. This is an accepted trade-off for a single-CM
    topology; the mitigations are (a) a fast node replacement in 2a, (b) treating a
    2a outage as a P1, and (c) the roadmap item to make the CM AZ-flexible.

| Failure | Blast radius | Recovery |
|---------|--------------|----------|
| One indexer pod | RF/SF self-heals from peers + SmartStore | operator reschedules; `make sok-health` to confirm RF/SF met |
| One SHC member | search continues on remaining members | operator reschedules; KV re-replicates |
| CM pod (2a node alive) | search paused seconds–minutes | operator reschedules the CM automatically |
| **AZ 2a lost** | **CM down → search outage**; site-2 indexers unaffected | restore 2a capacity; CM reschedules; then `make sok-health` |
| Whole cluster | none to data (S3 is source of truth) | `SOK START` rebuilds; `make sok-kvstore-restore` re-seats KV |

!!! warning "Restarting the EC2 estate after a prod SOK run"
    Once prod SOK has attached to the prod SmartStore bucket, 
    the bucket carries the SOK generation's GUIDs.
    The EC2 CM's next cold boot will likely hit the same RF/SF fixup stall SOK
    hit — run **`./scripts/rf-remediate.sh prod`** (the EC2/SSM variant) after
    the estate boots; it rolling-restarts the peers only when the stall
    signature is present. The SOK-side twin is `make sok-rf-remediate`.

SHC members should be **spread across AZs** (topology-spread) so a single-AZ loss
never takes a majority — tracked as a prod-profile item; dev runs a single
Standalone SH so it does not apply there.

## IP capacity (shared /26 subnets)

The cluster borrows the prod VPC's `default-{a,b,c}` subnets — **/26s, ~59
usable IPs each, shared with the prod EC2 estate**. The vpc-cni addon is tuned
(`WARM_IP_TARGET=4`, `MINIMUM_IP_TARGET=8`) so nodes don't hoard a full ENI's
worth of warm IPs (15 on t3.xlarge). If a future shape's pod density approaches
subnet capacity anyway, the escalation path is a **secondary VPC CIDR + CNI
custom networking** (pods move to a dedicated large CIDR; nodes stay put) — an
account-layer change to plan deliberately, not an eks-layer tweak.

## EKS version & the support cost cliff
ß
!!! danger "Standard support for EKS 1.34 ends 2026-12-02"
    After that date the control plane moves to **extended support at ~6× the
    hourly rate** (~$0.60/hr vs ~$0.10/hr) until 1.34 leaves extended support.
    The dev nightly-rebuild masks this (the cluster barely exists), but **prod
    runs always-on**, so the cutover is a real, recurring bill. **Owner: whoever
    holds the Splunk platform.** Put 2026-11-01 in the calendar to start the
    upgrade so it lands before the cliff.

**Upgrade path (1.34 → 1.35), gated on the Splunk Operator supporting 1.35:**

1. Confirm the installed **Splunk Operator** version supports the target EKS
   version (release notes) — the operator, not EKS, is the pacing item.
2. Bump the eks module's `cluster_version` (`terraform/layers/eks`) and the addon
   versions (`addons.tf`) to the 1.35-compatible releases.
3. **Dev first:** `SOK START env=dev` on the new version, then `make sok-health
   env=dev`. Because dev is disposable, a failed upgrade costs nothing — destroy
   and retry.
4. **Prod:** control-plane upgrade is online; node groups roll (surge) — the
   single-CM search pause applies during the CM's node roll, so schedule a window.
5. `make sok-health env=prod` green ⇒ done. Roll back by pinning the previous
   `cluster_version` and re-applying if the operator misbehaves.

Because prod is always-on, treat the upgrade as a planned change, not a nightly
rebuild. Keeping the EKS version current also keeps the control-plane bill at the
standard rate.

## Alerting

Lifecycle failures (START / STOP / CHECKS) post to Slack when the repo secret
`SLACK_WEBHOOK_URL` is set — a **failed nightly STOP is the one that matters
most** (the cluster keeps billing overnight). Until the secret is set the
notify steps no-op and the Actions tab is the only signal.

!!! note "Open decision — in-cluster alerting"
    Workflow alerts don't cover in-cluster failures (the 6-hourly KV backup
    CronJob, operator reconcile errors, pod crash-loops between CHECKS runs).
    Options, in rough order of effort: (a) a tiny watchdog CronJob that posts
    to the same Slack webhook on `kubectl get jobs` failures; (b) CloudWatch
    Container Insights + alarms (adds an agent + a few $/mo); (c) ship cluster
    events into Splunk itself (the estate's native home) and alert there.
    Pick one before the prod cutover — tracked as OPS-4.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Indexer `FATAL` on SmartStore at boot | `sts.<region>` DNS race starving IRSA | node-local DNS cache (installed); confirm the `node-local-dns` DaemonSet is Running |
| Multisite peer rejected ("no site configuration") | `splunk.site` alone doesn't write `[general] site` | the CR writes `server.conf [general] site` explicitly — check the peer's `defaults` |
| SmartStore 403 (looks like IAM) | shared prod VPC S3 endpoint policy | allowlist the bucket in the VPC-endpoint policy (`custom_s3_bucket_access`) |
| `sok-health` says "no licence" but it's fine | a stale build of the script using `_internal call` | fixed — the licence probe uses curl; re-pull `scripts/sok-health.sh` |
| Splunk Web (external ALB) bounces to `127.0.0.1:8000` | ALB doesn't send `X-Forwarded-Host` | `web.conf tools.proxy.local=Host` (set by the external-web flag) |

See the design docs' caveat register and the [review](reviews/index.md) for the
open hardening items behind these.

## Community lessons adopted (credits)

Several operational choices here follow **Gareth Anderson (SplunkTrust)** — with
thanks:

- [SOK: lessons from our implementation (pt 1)](https://medium.com/@gjanders03/splunk-operator-for-kubernetes-sok-lessons-from-our-implementation-0982774e42fc)
- [SOK: lessons from our implementation (pt 2)](https://medium.com/@gjanders03/splunk-operator-for-kubernetes-sok-lessons-from-our-implementation-part-2-d076715bc9cb)
- [Splunk Lantern: SOK — Advanced operational learnings](https://lantern.splunk.com/Platform_Data_Management/Transform_Pipelines/Splunk_Operator_for_Kubernetes%3A_Advanced_operational_learnings)

Adopted from his work (all **merged**, commits `50c883a` + `a5e3625`): the
**probe overrides** (`crs.tf`), **graceful `splunk offline` before teardown**
(stop workflow — unclean kills were his #1 cause of corrupted SmartStore
buckets, and corrupt buckets persist into S3),
**`singleProcessOOMKill` + node `shutdownGracePeriod`** kubelet config (eks
layer — one OOMing search must not SIGKILL splunkd under cgroupsv2), and the
**CM↔indexer soft anti-affinity**.

The **full lesson-by-lesson adoption matrix (27 rows, DONE/queued) is the single
source of truth in [Community lessons](kubernetes-sok-community-lessons.md)** —
the still-queued items (MC-Apply automation, the #893 app-deletion drift check,
search memory guardrails, plaintext-9997 verification) are tracked as task #55
with the executable spec in
[Handoff, lessons remainder](handoff-sok-lessons-remainder.md).
