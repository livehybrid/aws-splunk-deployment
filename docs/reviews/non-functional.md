# Non-functional review, SOK implementation

!!! info "Part of the [full SOK review](index.md)"
    July 2026 · **13 findings**, 5 High, 4 Medium, 4 Low. Pricing sanity-checked live against the AWS Pricing API. See the [review index](index.md) for the prioritised remediation plan.

!!! success "Remediation status"
    **DONE 4 · PARTIAL 5 · OPEN 4.** NFR-9 cost restatement, NFR-4 cliff documentation, NFR-5 CNI config and NFR-6 per-role PVC plumbing are DONE. Open: NFR-2, NFR-7, NFR-10, NFR-13. Several PARTIALs are deliberate build-out-test deviations (NFR-1 Burstable, NFR-3 no general-c) rather than gaps.

Scope reviewed: `terraform/layers/eks/*`, `terraform/layers/sok/*`, `terraform/layers/_shared/{variables.tf,vars/{dev,prod}.tfvars}`, `docs/kubernetes-sok{,-plan,-overview}.md`, `infracost.yml`, SOK workflows/scripts, account-layer VPC endpoints. Pricing sanity-checked live against the AWS Pricing API (eu-west-2, July 2026): t3.xlarge $0.1888/hr, m6a.xlarge $0.1998/hr, m6i.xlarge $0.2220/hr, gp3 $0.0928/GB-mo; `describe-instance-types` confirmed t3.xlarge = 4 vCPU/16 GiB, 4 ENI × 15 IPs, EBS baseline 695 Mbps.

## Findings

### [NFR-1] Prod pods are Burstable QoS with 3:1 memory overcommit, the K7 "Guaranteed" intent has no implementation or plumbing
- **Severity**: High
- **Status**: ◐ **PARTIAL**, a `var.sok_pod_resources` variable is added and wired via `crs.tf:48` (the plumbing the finding asked for) (DONE). **Residual: `prod.tfvars:202-205` still sets Burstable (200m/1Gi req, 2/4Gi lim), deliberately, for the workload-free build-out; prod Guaranteed is still deferred to cutover.**
- **Evidence**: `terraform/layers/sok/crs.tf:43-46`, a single unconditional local: `requests = { cpu = "250m", memory = "2Gi" }`, `limits = { cpu = "2", memory = "6Gi" }`, merged into every CR via `cr_common` (line 59). The comment at line 42 says "Prod goes Guaranteed (K7)" and `docs/kubernetes-sok-plan.md:176` declares "requests=limits (Guaranteed QoS)" for prod, but there is no per-environment conditional and no `sok_*` variable in `terraform/layers/_shared/variables.tf:348-448` to set resources, so applying `prod.tfvars` today deploys Burstable pods.
- **Impact**: On the 2b node (1× t3.xlarge, ~14.5Gi allocatable), the two hard-pinned site2 indexers alone carry 12Gi of limits against 4Gi of requests; add one bin-packed SHC member and limits reach 18Gi on a 16GiB node. Under real load (bucket fixups after an AZ event, search storms) pods over their 2Gi request are the kubelet's first eviction targets, i.e. the cluster sheds *indexers* precisely when it is repairing RF. With Guaranteed QoS the same pressure would instead surface as Pending pods (a clean capacity signal). Also 6Gi is half Splunk's 12GB reference memory per indexer, plan line 176 records this as a deliberate lab deviation, but Burstable makes the shortfall dangerous rather than merely slow.
- **Recommendation**: Add a `sok_resources` (or per-role) variable; prod sets requests=limits (e.g. 2 CPU/6Gi Guaranteed) before cutover. Keep dev's cheap Burstable shape via dev.tfvars.
- **Effort**: S

### [NFR-2] Burstable t3.xlarge nodes for an always-on prod cluster, CPU-credit economics invert above ~46% sustained load
- **Severity**: High
- **Status**: ○ **OPEN**, `prod.tfvars:196-198` now uses `t3.large ×4` (build-out-test sizing, not prod-ready) with **no** `credit_specification` and **no** CPUCreditBalance alarm; the note says "revert to bigger nodes for load". The m6a-vs-t3-vs-alarm always-on decision is still pending.
- **Evidence**: `terraform/layers/_shared/vars/prod.tfvars:168-171`, `general-a`/`general-b` are `t3.xlarge`; `terraform/layers/eks/eks.tf:59-67` sets `ON_DEMAND` but no credit specification (t3 therefore launches in its default `unlimited` mode).
- **Impact**: t3.xlarge baseline is 40%/vCPU = 1.6 sustained vCPU per node. Prod packs 2 indexers (2-CPU limit each) per node plus SHC/control pods, steady lab ingest likely sits under baseline, but always-on forwarder traffic + scheduled searches + SmartStore uploads + fixup storms will exceed it. In `unlimited` mode that is a silent surcharge of $0.05/vCPU-hr: a node sustained at 100% costs +$87.6/mo (t3.xlarge $137.8 → $225.4/mo, dearer than m6i.xlarge at $162). Break-even vs m6a.xlarge (+$8.0/mo, full 4 vCPU, 1250 vs 695 Mbps EBS baseline, AVX2 OK for Splunk 10) is only ~46% average node CPU. If the account default were flipped to `standard`, the failure mode becomes throttling to 1.6 vCPU → indexing-queue backpressure instead. t3.xlarge's 695 Mbps (~87 MB/s) EBS baseline is also shared across all pods' gp3 volumes on the node, below a single volume's 125 MB/s gp3 ceiling.
- **Recommendation**: For prod cutover use m6a.xlarge (+$24/mo total for 3 nodes), cheaper than one node's worst-month surplus; at minimum alarm on `CPUSurplusCreditBalance`/`CPUCreditBalance` per node.
- **Effort**: S (tfvars-only)

### [NFR-3] AZ eu-west-2a is a search-plane single point of failure: CM hard-pinned + SHC quorum likely co-located
- **Severity**: High
- **Status**: ◐ **PARTIAL**, an SHC `topologySpreadConstraints` on zone is added (`crs.tf:374-380`, ScheduleAnyway) and the "2a loss = search outage, ingest survives" DR posture is documented in the runbook (DONE). **Residual: no `general-c` node group (only 2 AZs, so a 3-member SHC still co-locates 2 in one AZ), and the CM stays hard-pinned to 2a (requiredDuringScheduling).**
- **Evidence**: `terraform/layers/sok/crs.tf:143`, ClusterManager gets `affinity_for_zone["eu-west-2a"]` (requiredDuringScheduling); lines 305-336, SHC `replicas = 3` (line 319) with **no** zone affinity/spread (only the operator's default preferred hostname anti-affinity); `prod.tfvars:168-171` puts 2 of 3 nodes in 2a, and the tfvars comment (lines 166-167) itself admits "add a general-c … for full SHC AZ-spread when right-sizing". EBS PVCs are AZ-locked (`WaitForFirstConsumer`, `terraform/layers/eks/storage.tf:26`); LM/MC/operator have no affinity but will mostly bind PVCs in 2a where the capacity is.
- **Impact**: Loss of 2a takes: the CM (hard pin + PVC, cannot reschedule anywhere, RTO = AZ outage duration), both site1 indexers, and probabilistically 2 of 3 SHC members (one per node under hostname anti-affinity → 2 in 2a) → captain quorum lost → **search fully down**, plus no bucket fixups/bundle pushes. Ingest survives (NLB → site2 peers, data has a searchable cross-site copy per `site_search_factor total:2`, `prod.tfvars:64-65`), and recovery is automatic when 2a returns, but the SOK operator offers no CM HA, so this is an accepted-by-design RTO that is currently undocumented. Loss of 2b, by contrast, degrades nothing user-visible (origin:2/total:3 leaves searchable copies in site1). Also note whole-site2 = one physical node (`general-b desired=1`): a plain node failure removes an entire site until the ASG replaces it (~5-10 min + up-to-20-min Splunk startup budget, `crs.tf:20-33`).
- **Recommendation**: Before cutover: add a `general-c` node group and a preferred zone-level podAntiAffinity on the SHC CR so no AZ holds 2 members; document "2a down = search outage, ingest continues" as the accepted DR posture with its RTO.
- **Effort**: M

### [NFR-4] EKS 1.34 support cliff on 2026-12-02: +$365/mo or an upgrade gated on Splunk Operator releases
- **Severity**: High
- **Status**: ✅ **DONE (documented + owned)**, the runbook documents the cliff, a 2026-11-01 calendar go/no-go, and SOK-release gating (=OPS-8). The upgrade execution itself is future work.
- **Evidence**: `terraform/layers/_shared/variables.tf:358-363`, "SOK 3.1.0 supports K8s 1.25-1.34; … 1.34 exits standard EKS support 2026-12-02, after that the parked control plane bills 6x"; the [design study cost table](../kubernetes-sok.md#cost-picture-prod-shaped-eu-west-2-july-2026) ($73 → $438/mo).
- **Impact**: <5 months away. An always-on prod control plane in extended support adds $365/mo, bigger than the entire projected EC2-vs-SOK compute delta. The upgrade path is not fully in your control: SOK 3.1.0's ceiling is 1.34, so you need a newer operator release (and a validated Splunk image pairing) before EKS 1.35. This converts "annual K8s upgrade" into a hard, dated, third-party-gated cost trigger, and each future year repeats it.
- **Recommendation**: Calendar a go/no-go for ~Oct 2026: if no SOK release supports 1.35, decide explicitly between eating extended support or deferring the cutover (the design study's keep-EC2 stance). Track operator releases in the repo docs.
- **Effort**: S (process), M (the eventual upgrade)

### [NFR-5] /26 subnets vs VPC-CNI defaults: prod node IP appetite can exhaust default-a, which is shared with dev EKS, the EC2 edge tier, endpoints and NLBs
- **Severity**: High
- **Status**: ✅ **DONE**, `eks/eks.tf:87-96` sets vpc-cni `configuration_values` with `WARM_IP_TARGET=4`, `MINIMUM_IP_TARGET=8`, capping per-node IP appetite. (The secondary-CIDR replan is noted as future.)
- **Evidence**: `prod.tfvars:19-21`, subnets are /26 (59 usable IPs each); `terraform/layers/eks/eks.tf:51-53`, `vpc-cni = { before_compute = true }` with **no** `configuration_values` (default `WARM_ENI_TARGET=1`, no prefix delegation); dev shares the same prod VPC/subnets (`dev.tfvars:58` `eks_vpc_name_tag = "prod"`); t3.xlarge = 4 ENI × 15 IPs (verified); ~10 interface endpoints exist in the account layer (`terraform/layers/account/vpc_default_ep.tf`) plus control-plane ENIs, NLB ip-target ENIs, and the hybrid EC2 HFs.
- **Impact**: With defaults, each t3.xlarge attaches a warm second ENI early → ~30 IPs per node. Prod `general-a` at desired=2 ≈ 60 IPs, more than the whole /26, before counting the dev cluster's node (same subnet), 2 control-plane ENIs per cluster, endpoint/NLB ENIs and HFs. Symptoms would be pods stuck `ContainerCreating` ("failed to assign an IP") on the first prod-shape bring-up or on scale to `max=3`. The VPC itself is only a /24 (`prod.tfvars:18`), so subnet growth needs a secondary CIDR.
- **Recommendation**: Set `configuration_values` on the vpc-cni addon (`WARM_IP_TARGET=2-4`, `MINIMUM_IP_TARGET≈10`), caps a node at ~15-20 IPs; plan a secondary VPC CIDR with larger EKS subnets as prod hardening (K7 already flags the private-subnet revisit).
- **Effort**: S (CNI config) / L (re-CIDR)

### [NFR-6] Every Splunk pod gets a 200Gi var PVC in prod, ~$130/mo of gp3 is allocated to roles that need almost none
- **Severity**: Medium
- **Status**: ✅ **DONE (plumbing)**, `sok_etc_storage_by_role`/`sok_var_storage_by_role` variables added (`variables.tf:472-479`), wired via `crs.tf:62,66` `lookup(...)`, so per-role right-sizing is now a tfvars edit. (Prod tfvars can set the small control/search volumes at cutover.)
- **Evidence**: `prod.tfvars:162-163`, `sok_etc_storage = "20Gi"`, `sok_var_storage = "200Gi"`; `crs.tf:48-62`, `local.storage` is merged into `cr_common`, which every CR (LM, MC, CM, IndexerCluster×2, SHC incl. its operator-created deployer) inherits with no per-role override.
- **Impact**: Prod = ~11 Splunk pods (4 idx + CM + LM + MC + 3 SHC + deployer) × 220Gi ≈ 2,420Gi gp3 ≈ **$225/mo**, 46% of the "$487/mo compute" headline, and the docs' "+EBS" caveat never quantifies it. ~7 of those pods (LM/MC/CM/deployer/SHC members) don't hold SmartStore cache; right-sizing them to ~30-50Gi var saves ~$110-130/mo (a 15%+ cut of total prod cost) at zero performance risk.
- **Recommendation**: Split storage locals per role (indexers keep the big var; control/search pods get small ones). The CRDs accept per-CR `varVolumeStorageConfig` already.
- **Effort**: S

### [NFR-7] Indexer SmartStore cache: 200Gi implemented vs 700Gi planned (K7) vs 500GB on the EC2 estate; no eviction tuning
- **Severity**: Medium
- **Status**: ○ **OPEN**, the per-role plumbing exists (NFR-6), but prod.tfvars sets no bigger per-role indexer cache override and no `maxGlobalDataSizeMB`/hotlist eviction knobs are in `crs.tf`/`configmaps.tf`. The 200Gi-vs-500Gi decision + eviction tuning is still open.
- **Evidence**: `prod.tfvars:163` (200Gi) vs `docs/kubernetes-sok-plan.md:634` ("700Gi var PVCs") vs `prod.tfvars:80` (`indexer_cache_volume_size = 500` on EC2). No `maxGlobalDataSizeMB`/`cacheManager`/hotlist settings anywhere in `crs.tf`/`configmaps.tf` (CRD supports them). The operator never resizes PVCs (`variables.tf:444-448` warns exactly this); mitigated by `allow_volume_expansion = true` (`storage.tf:27`) plus a manual-expand runbook note (plan K3.4).
- **Impact**: Working-set cache per indexer shrinks 2.5× vs the estate being replaced. At lab ingest the cache likely still holds weeks of data, but historical searches will thrash sooner (S3 GETs + latency); gp3 stays at baseline 3000 IOPS/125 MB/s (no `iops`/`throughput` params in `storage.tf:29-33`), which is adequate *per volume* but see the node-level 695 Mbps ceiling in NFR-2.
- **Recommendation**: Either raise indexer var to ≥500Gi at cutover (cost: +300Gi × 4 × $0.0928 ≈ +$111/mo, roughly what NFR-6 saves) or accept 200Gi deliberately and set hotlist/eviction knobs; test the manual PVC-expansion runbook once in dev.
- **Effort**: S

### [NFR-8] KV-store RPO is 6h; no restore-drill cadence; dev's Standalone has no backup at all
- **Severity**: Medium
- **Status**: ◐ **PARTIAL**, the stale "NOT validated" comments are removed and the mechanism is validated (DONE). **Residual: the schedule is still `0 */6 * * *` (6h RPO), there is no documented quarterly restore-drill cadence, and dev's Standalone is still unbacked (by design).**
- **Evidence**: `terraform/layers/sok/kvbackup.tf:146`, `schedule = "0 */6 * * *"`; header line 14: "⚠ NOT yet validated end-to-end (needs a live SHC, dev has no SHC)". Restore is a manual script (`scripts/sok-kvstore-restore.sh`); no documented drill cadence anywhere in docs/.
- **Impact**: Up to 6h of KV writes (lookups, dashboard state, app KV collections) lost on SHC destruction; and because dev runs a Standalone SH, the CronJob (gated on `enable_shc`, off in dev) does not run in dev at all.
- **Correction (actioned)**: The CronJob-derived backup Job *and* the restore path **were** validated end-to-end against the live multisite dev SHC (backup → S3 SSE-KMS upload → restore into the KV-store captain), so the mechanism works. The `⚠ NOT yet validated` comments in `kvbackup.tf` and `sok-kvstore-backup.sh` have since been **removed** (=OPS-5). The genuine residual gaps are the 6h RPO, the absent restore-drill cadence, and dev's Standalone KV store having no backup.
- **Recommendation**: On first prod-shape bring-up, run the CronJob manually and verify the S3 object; tighten schedule to hourly if KV content matters ($ cost is nil); document a quarterly restore drill.
- **Effort**: S

### [NFR-9] The honest cost comparison is "always-on SOK vs park-capable EC2", and SOK loses it; the earlier ~$487-570/mo figure understated total by ~50%
- **Severity**: Medium
- **Status**: ✅ **DONE**, the [overview](../kubernetes-sok-overview.md#how-we-run-it) and the [design study cost table](../kubernetes-sok.md#cost-picture-prod-shaped-eu-west-2-july-2026) are restated to the EBS-inclusive **≈ $750/mo all-in** figure with the STOPPED-floor (~$73/mo pause model, unshipped) vs DESTROYED-floor (~$1-2/mo) distinction and park-capability as the deciding criterion. (The Cost Explorer tag report is a future add.)
- **Evidence**: pre-fix the design-study table showed +$73/mo control plane, parked EC2 ~$8/mo vs parked EKS ~$73+EBS, extended-support $438/mo, and the overview said "≈ $490-570/mo"; `infracost.yml` explicitly notes the sok layer isn't costed (only eks + foundation). Verified prices: 3× t3.xlarge = $413.5/mo, EKS $73, PVCs ≈ $225 (NFR-6), 2 NLBs ≈ $37+LCU, inter-AZ replication at lab scale <$5/mo (origin:2/total:3 sends ~1 compressed searchable copy cross-AZ; S3 via the **gateway** endpoint is free, confirmed `vpc_default_ep.tf:25-37`).
- **Impact**: Realistic always-on prod SOK ≈ **$750/mo**, not $487-570, vs the EC2 estate's ≈ $833/mo *always-on* or materially less with its proven nightly park. The saving claimed for SOK compute evaporates once EBS is counted, and NFR-4 can flip it negative. Fragility: the plan's own K7 sizing (m6i.2xlarge per indexer, plan §1 line 176) would take compute alone to ~$1,300/mo, the implemented t3 shape is the *cheap deviation*, so "right-sizing risk" is the single biggest cost unknown. Infracost CI will not catch PVC growth since the sok layer is un-costed.
- **Recommendation**: (Actioned) restate the cost section with the EBS-inclusive number and the park-capability asymmetry as the decision criterion; still to add, a monthly Cost Explorer tag report on the `splunk.livehybrid.com/deployment-model=sok` tag (`eks.tf:88-90`).
- **Effort**: S

### [NFR-10] Site2 exists on exactly one node and replica counts are symmetric-only; adding a third site is a code change, not tfvars
- **Severity**: Low
- **Status**: ○ **OPEN**, `crs.tf` `local.sites` still hardcodes `{site1,site2}`, not derived from `var.available_sites`. (Low, non-blocking.)
- **Evidence**: `prod.tfvars:170`, `general-b desired=1, min=1, max=2`; `crs.tf:67-70`, `local.sites` hardcodes `{ site1 = eu-west-2a, site2 = eu-west-2b }`; `sok_indexer_replicas` is one number applied to every site CR (`crs.tf:236`); control-plane subnets pinned to a+b (`terraform/layers/eks/main.tf:49-52`).
- **Impact**: Node-group rolls in 2b work (max=2 gives surge room, PDB `minAvailable=1` per site, `pdb.tf:42`, sequences evictions), but a site3 needs edits in crs.tf + `available_sites` + a new node group; per-site asymmetric scaling (e.g. 3+2) is impossible without a new variable shape. ENI max-pods (58/node) is not a constraint at this scale, subnet IPs (NFR-5) bind first.
- **Recommendation**: Make `local.sites` derive from `var.available_sites` and consider a per-site replicas map when a third site becomes plausible; none of this blocks cutover.
- **Effort**: M

### [NFR-11] Operator and CM are single replicas, bounded, mostly-acceptable control-plane RTO; quantify and accept
- **Severity**: Low
- **Status**: ◐ **PARTIAL**, the watchdog (`sok/alerting.tf`) alerts on between-run failures and the CM-AZ RTO is in the runbook (=NFR-3/OPS-14). **Residual: a separate "operator Deployment unavailable >15 min" alert is not implemented.**
- **Evidence**: `operator.tf:56-103`, no `replicaCount` override (chart default 1), requests trimmed to 100m/256Mi (lines 95-98); no HA option exists for ClusterManager in SOK. Probe budget: startup up to 40×30s = 20 min, CM liveness 14×30s = 7 min (`crs.tf:20-37`).
- **Impact**: Operator pod loss: reconciliation pauses (running pods unaffected), minutes, self-healing. CM pod loss within 2a: STS reschedule to the other 2a node + Splunk start ≈ 10-25 min with no fixups/bundle pushes meanwhile; ingest and search continue on the last generation. These are fine for the workload; the *unbounded* case is the AZ pin covered in NFR-3.
- **Recommendation**: Document the two RTOs in the ops doc; alert on operator Deployment unavailability >15 min.
- **Effort**: S

### [NFR-12] Nightly dev hot-bucket roll is best-effort and silent on failure; dev RPO = since-last-roll by design
- **Severity**: Low
- **Status**: ◐ **PARTIAL**, a warning annotation fires when no peers match (`sok-stop.yml:111`) and the graceful `splunk offline` path is added (DONE-ish). **Residual: per-index roll failures inside the loop are still `|| true` silent, and the prod path still shares the `|| true` pattern (fail-closed prod path not yet enforced).**
- **Evidence**: `.github/workflows/sok-stop.yml:31` (cron 21:30 UTC), lines 89-94, per-index `roll-hot-buckets … || true` before destroy; dev is RF1/SF1 single indexer (`dev.tfvars:88-91`).
- **Impact**: If the roll fails (auth, pod naming, timing) the workflow proceeds and that day's un-rolled hot data is lost with no signal. Acceptable for disposable dev, but the same script pattern is earmarked as the prod pre-stop mechanism (plan K7.3.1 requires a supervised full roll+drain), carrying `|| true` into prod would be a data-loss bug. In prod steady state, abrupt single-pod/AZ loss loses nothing: hot buckets replicate cross-site at stream time (origin:2/total:3), so RPO≈0 short of a simultaneous two-AZ loss.
- **Recommendation**: Emit a workflow warning annotation when the roll fails; keep the prod stop path fail-closed.
- **Effort**: S

### [NFR-13] Prod-shape RTO is extrapolated, not measured
- **Severity**: Low
- **Status**: ○ **OPEN**, the runbook mentions the build-out test but publishes no measured end-to-end RTO/RPO DR statement. (Dev full bring-up is now recorded at ~30-45 min in the runbook lifecycle table, but the prod-shape rehearsal RTO/RPO is still unpublished.)
- **Evidence**: Dev full bring-up observed ~30-45 min (checks allow ~8-10 min cluster + Splunk, 12×120s retry envelope, `sok-checks.yml:7,66-75`; helm operator wait 900s, `operator.tf:67`). Prod adds SHC bootstrap, 2 IndexerCluster CRs, KV restore (manual), forwarder repoint; K7 rehearsal is designed (`kubernetes-sok-plan.md:643-668`) but explicitly gated/never run, and "same-bucket reattach by a new SOK cluster is undocumented territory" (line 715).
- **Impact**: Realistic prod disaster-rebuild RTO is likely 1.5-3h including KV restore and checks, probably fine for this estate, but it is currently a guess, and the rebuild *is* the stated rollback/DR strategy.
- **Recommendation**: Time the dev-based prod-shape rehearsal (K7.3 dev pass) end-to-end and record RTO/RPO numbers in the ops doc as the DR statement.
- **Effort**: M (one supervised rehearsal)

## Strengths (brief)

- **SmartStore data path is cost-optimal and correct**: S3 via a gateway endpoint (`vpc_default_ep.tf:25-37`, route-table association, zero per-GB cost), no NAT anywhere, SSE-KMS overlay done properly via `defaultsUrl` ConfigMap, and inter-AZ replication cost is genuinely negligible at this scale.
- **Real Splunk-on-K8s operational scar tissue is encoded**: THP disabled + ulimits via pre-nodeadm (`eks/files/node-prep.sh`, avoids Splunk's documented ≥30% penalty), node-local DNS cache with `force_tcp` (kills the STS/IRSA race), probe overrides sized to Splunk startup reality, `WaitForFirstConsumer` + per-AZ affinity (avoids SOK #1152 cross-AZ volume wedge), hand-built PDBs including a quorum-aware SHC PDB (operator provides none), `startwebserver=0` on peers.
- **Data-safety topology is sound**: origin:2/total:3 + SF total:2 gives true single-AZ survivability of all *ingested* data; `constrain_singlesite_buckets=false` carries the EC2 migration lesson; hot buckets rolled before planned destroys; PVC delete-ordering prevents orphaned EBS.
- **Cost discipline in dev**: nightly destroy (~$3.4/day when running, ~$1-2/mo at rest), spot only where stateless, EC2/SOK exclusivity guard prevents double-running against one SmartStore bucket, per-layer Infracost.

## Suggested follow-up tasks (ordered one-liners)

1. Add a per-env `sok_resources` variable and set requests=limits (Guaranteed) in prod.tfvars before any cutover (NFR-1).
2. Switch prod `eks_node_groups` to m6a.xlarge (+$24/mo) or add CPU-credit CloudWatch alarms with a documented decision (NFR-2).
3. Set vpc-cni `configuration_values` (WARM_IP_TARGET/MINIMUM_IP_TARGET) and sketch the secondary-CIDR plan for larger subnets (NFR-5).
4. Split PVC sizing per role, small var volumes for LM/MC/CM/SHC/deployer, keep 200Gi+ for indexers, saving ~$110-130/mo (NFR-6, funds NFR-7).
5. Add `general-c` + zone anti-affinity for the SHC and document the "2a loss = search outage, ingest survives" DR posture (NFR-3).
6. Book the EKS 1.35/SOK-release go/no-go for October 2026 and record the extended-support cost trigger in the ops doc (NFR-4).
7. First prod-shape bring-up: manually fire the kvbackup CronJob, verify the S3 artifact, and set a quarterly restore-drill cadence (NFR-8).
8. Run and time the K7 dev rehearsal end-to-end; publish measured RTO/RPO as the DR statement (NFR-13).
9. Rewrite the cost section with the EBS-inclusive ~$750/mo figure and the park-capability asymmetry as the deciding criterion (NFR-9).
10. Make the hot-bucket roll fail loudly (workflow annotation) and fail-closed in the future prod stop path (NFR-12).
11. Derive `local.sites` from `var.available_sites` when a third site/asymmetric scaling becomes plausible (NFR-10).
