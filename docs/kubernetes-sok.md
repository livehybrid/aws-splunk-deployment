# Splunk Operator for Kubernetes (SOK) — design study

This page is the output of a deep-dive into migrating the M3 deployment to the
[Splunk Operator for Kubernetes](https://github.com/splunk/splunk-operator)
on EKS, and into offering **EC2 vs SOK as a per-workspace toggle**. Every
load-bearing claim below was adversarially verified against primary sources;
citations inline. A phase-by-phase build plan derived from this study lives
at [SOK implementation plan](kubernetes-sok-plan.md), the day-to-day working
model at the [SOK overview](kubernetes-sok-overview.md).

## Verdict

**Feasible and officially supported — with three findings that change the
calculus:**

1. **M3 on SOK is a documented, Splunk-supported pattern.** The
   [SOK Applied SVA](https://help.splunk.com/en/splunk-enterprise/splunk-validated-architectures/applied-svas/splunk-operator-for-kubernetes)
   (updated 2026-02) explicitly lists M2/M12, M3/M13 and M4/M14 as fully
   supported, and SOK is the *only* supported way to run distributed Splunk
   Enterprise in containers (bare docker-splunk support covers S1/UF/HF
   only). Our exact topology — 2 sites = 2 AZs, 2 peers per site,
   `origin:2,total:3`, SHC at `site0` — maps 1:1 onto the documented
   "Multipart IndexerCluster" pattern.

2. **The nightly-stop cost model breaks.** An EKS control plane cannot be
   stopped: a *parked* cluster (nodes → 0, cluster kept alive) still costs
   **~$73/mo** at zero nodes (standard support) and silently jumps to
   **~$438/mo** when its Kubernetes version ages into extended support —
   versus **~$8/mo** for a parked EC2 estate. Worse, *nobody has ever
   documented or publicly tested* a park/resume cycle on SOK, and there is a
   **live, unresolved KV-store cold-restart wedge on Splunk 10.x**
   ([#1875](https://github.com/splunk/splunk-operator/issues/1875),
   open with zero maintainer response;
   [#1489](https://github.com/splunk/splunk-operator/issues/1489) closed
   "raise a support ticket"). So the shipped build does **not** use the pause
   model at all: its cost guard is a full **destroy/recreate of the compute**
   (`sok` + `eks`, control plane included), which treats every PVC as
   disposable — losing unrolled hot buckets and KV-store content each cycle,
   but landing at a **destroyed floor of ~$1-2/mo** (persistent S3 + KMS only).
   The ~$73/mo is therefore a floor SOK *would* pay under a pause model it
   avoids, not a floor it sits at. See the [cost picture](#cost-picture-prod-shaped-eu-west-2-july-2026) below.

3. **SOK manages topology, not security or lifecycle.** Everything this
   repo is proudest of — fail-closed per-host PKI, `sslVerifyServerCert`,
   SmartStore SSE-KMS with a pinned key, nightly cost guard, git-driven app
   deploys — is **outside the operator's scope** and must be rebuilt as
   defaults-yaml overlays, App Framework apps mounted from S3, and new
   operational glue. The operator does no data-plane TLS at all (S2S and
   Web are plaintext between pods by default), cannot express SSE-KMS in
   its SmartStore CR, and cannot pull apps from git.

## What SOK is

| Fact | Detail |
| --- | --- |
| Current release | **3.1.0** (2026-03-30); 3.0.0 (2025-09) added Splunk 10.x; active development (SmartBus/ingestion-separation CRDs landed in 3.1.0) |
| Support posture | "SPLUNK SUPPORTED" as an **Extension** (weaker tier than core Enterprise — P3-target response); simultaneously "community developed" |
| Kubernetes | 1.25–1.34; **K8s 1.34 requires Splunk 9.4.9+/10.0.4+/10.4+** (IRSA token format change). EKS + GKE are Splunk's own dev/test platforms |
| Splunk versions | 10.4+ explicitly in the 3.1.0 support matrix — our 10.4.0 qualifies. 10.x images require operator ≥3.0.0 **plus** `SPLUNK_GENERAL_TERMS=--accept-sgt-current-at-splunk-com` |
| Architecture | Go operator + 11 CRDs → StatefulSets running `splunk/splunk` images; conf rendering is done *inside each pod* by splunk-ansible, fed an operator-generated `default.yml` (`SPLUNK_DEFAULTS_URL`) |
| CRDs | ClusterManager, IndexerCluster, SearchHeadCluster (deployer built in), LicenseManager, MonitoringConsole, Standalone (+ legacy ClusterMaster/LicenseMaster, + new IngestorCluster/Queue/ObjectStorage) |
| Images | `splunk/splunk` is **x86-64 only** — no Graviton for Splunk pods (operator image itself is multi-arch) |
| Install | Helm charts `splunk/splunk-operator` + `splunk/splunk-enterprise` from `https://splunk.github.io/splunk-operator/`; **CRDs are NOT in the chart** since 3.0.0 (Helm 1MB limit) — apply `splunk-operator-crds.yaml --server-side` separately |

## The M3 topology as SOK custom resources

One namespace, one ClusterManager, **one IndexerCluster CR per site**, SHC
at site0 — all wired by `clusterManagerRef`
([MultisiteExamples.md](https://github.com/splunk/splunk-operator/blob/main/docs/MultisiteExamples.md)):

```yaml
apiVersion: enterprise.splunk.com/v4
kind: ClusterManager
metadata:
  name: cm            # -> service splunk-cm-cluster-manager-service
spec:
  affinity:           # pin CM to eu-west-2a
    nodeAffinity: {...topology.kubernetes.io/zone In [eu-west-2a]...}
  smartstore:         # volumes/indexes/cacheManager — see caveat below
    volumes:
      - name: remote-store
        endpoint: https://s3-eu-west-2.amazonaws.com
        path: livehybrid-splunk-prod-splunk-smartstore-prod
        # no secretRef -> IRSA via spec.serviceAccount
  defaults: |-
    splunk:
      site: site1
      multisite_master: localhost
      all_sites: site1,site2
      multisite_replication_factor_origin: 2
      multisite_replication_factor_total: 3
      multisite_search_factor_origin: 1
      multisite_search_factor_total: 2
      conf:                              # arbitrary conf via splunk-ansible
        - key: server
          value:
            directory: /opt/splunk/etc/system/local
            content:
              clustering:
                constrain_singlesite_buckets: false
---
apiVersion: enterprise.splunk.com/v4
kind: IndexerCluster
metadata: {name: idxc-site1}
spec:
  replicas: 2                            # origin-count floor — 2/site is valid
  clusterManagerRef: {name: cm}
  affinity: {...zone In [eu-west-2a]...}
  defaults: |-
    splunk: {multisite_master: splunk-cm-cluster-manager-service, site: site1}
# idxc-site2: same, site2 / eu-west-2b
---
apiVersion: enterprise.splunk.com/v4
kind: SearchHeadCluster
metadata: {name: shc}
spec:
  replicas: 3                            # deployer is created by this CR
  clusterManagerRef: {name: cm}
  defaults: |-
    splunk: {multisite_master: splunk-cm-cluster-manager-service, site: site0}
```

Plus `LicenseManager`, `MonitoringConsole` CRs (both trivial), and —
because there is **no HeavyForwarder or DeploymentServer CRD** —
`Standalone` CRs repurposed for the HF tier (community pattern, not
documented; a Splunk docs PR codifying it is unmerged).

!!! warning "Do not use the Helm chart's `sva.m4` preset"
    The `splunk-enterprise` chart advertises an M4 preset, but it
    **hardcodes** `multisite_replication_factor_origin: 1 / total: 2` and
    **ignores `defaults`** on the CM and IndexerClusters when enabled. Our
    `origin:2,total:3` and `constrain_singlesite_buckets=false` cannot be
    expressed through it. Manage raw CRs instead (via the
    `alekc/kubectl` Terraform provider or a GitOps stage) — the
    `kubernetes_manifest` resource also fails at plan time while CRDs
    don't exist yet.

## Mapping the existing build onto SOK

What each hard-won behaviour in this repo becomes:

| Today (EC2) | Under SOK | Notes |
| --- | --- | --- |
| Packer AMI (AL2023 + RPM) | `splunk/splunk:10.4.x` image (UBI9) | Packer path retired for SOK; pin image per CR. THP/ulimits move to **node** config (custom EKS AMI/launch template — Splunk cites ≥30% degradation with THP on) |
| Per-instance ASGs + Name-tag identity | StatefulSet ordinals | Native — the whole identity pattern disappears |
| EBS cache claim by Name tag | `varVolumeStorageConfig` PVC (SmartStore cache lives on the var PVC) | PVC resize is **not** operator-orchestrated ([#558](https://github.com/splunk/splunk-operator/issues/558)) — size generously up front |
| `data_volume_filesystem` xfs/ext4 mkfs toggle | StorageClass `csi.storage.k8s.io/fstype: xfs\|ext4` | Clean 1:1 mapping (EBS CSI, gp3 + iops/throughput params) |
| Bootstrap .tpl scripts | splunk-ansible `defaults` yaml per CR | Use `defaultsUrl` → ConfigMap, **not inline `defaults`** — every inline edit triggers a full rolling recycle |
| Multisite vars in tfvars | `defaults` on CM + per-site IndexerCluster CRs | Same semantics; AZ pinning via nodeAffinity |
| `constrain_singlesite_buckets=false` | splunk-ansible `conf:` key (above) or an app | Combination of two documented mechanisms — never shown together officially; **validate in dev** |
| SmartStore snippet w/ SSE-KMS + TLS | CR `smartstore` block **cannot express** `remote.s3.encryption=sse-kms`, `kms.key_id`, `sslVerifyServerCert`, `sslRootCAPath` | Must ship as an indexes.conf app layered over the operator-generated config, or abandon `spec.smartstore` for a fully self-managed app. Precedence/flap behaviour unverified — **top validation spike**. CA bundle inside UBI9 image: `/etc/pki/tls/certs/ca-bundle.crt` (same path as AL2023) |
| Instance profile + `imds_http_tokens=optional` | **IRSA** (`spec.serviceAccount`, no secretRef) | Officially supported (Splunk ≥9.0.5; token-refresh bug fixed in 9.3.2; fine on 10.4). IMDS is not involved at all. `AWS_STS_REGIONAL_ENDPOINTS=regional` required (EKS webhook injects it). Correction found during research: splunkd *does* support IMDSv2 via `server.conf [imds] imds_version=v2` (default v1) — our EC2 workaround reflects the default, not a hard product gap; worth retesting on EC2 too |
| Cert-issuer Lambda + per-host CSR, fail-closed | **No operator TLS management at all** | BYO certs in K8s Secrets mounted via CR volumes + conf in apps/defaults (Lantern pattern). cert-manager integration was drafted and **closed unmerged** (PR #1460; successor #1596 still draft). Operator's own REST client is `InsecureSkipVerify` — private-PKI server certs on 8089 are fine, but **`requireClientCert` on 8089 would break the operator and its probes**. S2S TLS: SOK configures 9997 as a *non-SSL* listener; the documented pattern is a second TLS listener on 9998 |
| `pass4SymmKey`/admin pw from Secrets Manager | Global secret `splunk-<ns>-secret` (keys: `password`, `pass4SymmKey`, `idxc_secret`, `shc_secret`, `hec_token`) | Pre-creatable — sync from Secrets Manager via External Secrets Operator (no official example; the PasswordManagement doc's prose key names are **wrong** — use the code's underscore names). Rotation = patch the secret; never via Splunk CLI |
| Apps from git (deployer/CM push scripts) | **App Framework: S3 only, no git** | CI must package each app as `.tgz`/`.spl` and publish to an apps bucket (same-filename rule for updates, Etag-based detection). Indexer apps go on the **CM's** appRepo (IndexerCluster CRs take no apps). No uninstall support; local-scope installs don't restart pods ([#1402](https://github.com/splunk/splunk-operator/issues/1402)) |
| DS for external UFs | **Nothing** — no DS CRD ([#1198](https://github.com/splunk/splunk-operator/issues/1198)), no deployment-apps delivery ([#1180](https://github.com/splunk/splunk-operator/issues/1180)) | Keep DS on EC2 (hybrid), or Standalone-as-DS with undocumented glue |
| Indexer discovery for forwarders | **Unsupported on Kubernetes** | Every external forwarder's outputs.conf changes at cutover: static NLB endpoint (+ `tlsHostname` for SNI if TLS passthrough) |
| ALB + host routing, EIPs, Route53 A records | AWS Load Balancer Controller (ALB for web — sticky sessions required; NLB for 9997/HEC) + external-dns | SOK's Ingress doc has no ALB examples (open since 2019) but the AWS-native pattern is standard. Splunk Web/REST **must be TLS end-to-end** — no gateway termination per SOK's own matrix |
| SSM sessions / `make ssm` | `kubectl exec` / `kubectl-splunk` plugin | `make ssm role=...` → `make kexec role=...` |
| checks workflow (SSM + REST) | CR `status.phase` (Ready/Error...), SHC `CaptainReady`, + same REST checks via `kubectl exec` | rf-remediate.sh port is straightforward |
| MC peer reconciler (systemd timer) | MonitoringConsole CR + `monitoringConsoleRef` | Operator-managed — reconciler retires |
| Rolling restarts / upgrades | Operator-driven: image bump → ordered CM→SHC→IDX **zone-by-zone**, peer decommission before every pod delete | Scale-down is graceful too (`enforce_counts=true` rebalance). But: any CR label/annotation edit triggers a full rolling recycle ([#1652](https://github.com/splunk/splunk-operator/issues/1652)); one un-Ready pod blocks all scaling ([#1646](https://github.com/splunk/splunk-operator/issues/1646)); no downgrades |
| Nightly stop (tfvars overlay → 0 instances) | **No equivalent.** Pause annotations stop reconciliation, not pods; IndexerCluster can't scale below the RF origin floor | Options: (a) nodegroups→0 + pause (unvalidated, KV-store wedge risk), (b) nightly EKS destroy/recreate (PVCs disposable, hot buckets lost), (c) accept always-on |
| use_spot | Don't. | AWS + community guidance: no Spot for stateful indexers; Auto Mode also unsuitable (21-day forced node recycling, per-instance surcharge, own EBS provisioner) |

## Ops-hardening notes from production users

The only substantive public production record is Gareth Anderson's series
([Lantern](https://lantern.splunk.com/Platform_Data_Management/Transform_Pipelines/Splunk_Operator_for_Kubernetes:_Advanced_operational_learnings) /
Medium, bare-metal K8s, Splunk 9.x, ~1yr+). Apply these from day one:

- **Raise probe thresholds** — default liveness probes kill busy indexers
  (unclean shutdown → SmartStore bucket-corruption risk). Use SOK 3.0.0+
  custom probe scripts (`splunk status`-based), startup `failureThreshold≈40`,
  liveness `≈30` on indexers.
- **preStop hook** running `splunk offline`/`stop` — node drains don't
  gracefully stop splunkd otherwise.
- **`defaultsUrl` ConfigMap, never inline `defaults`** (inline edits =
  rolling restart of everything).
- Verify `SPLUNK_SKIP_CLUSTER_BUNDLE_PUSH` defaults on (3.0.0+) — CM pod
  restarts used to trigger surprise full-cluster bundle-push restarts
  (fixed in Splunk 9.2.8/9.3.6/9.4.4+).
- Node-local DNS cache — a DNS blip at the wrong moment can wedge the CM
  below RF/SF permanently.
- Don't co-locate the CM on indexer nodes; create your own PDBs (operator
  makes none); Guaranteed QoS (requests=limits) on all Splunk pods.
- No published production multisite-on-SOK exists. We'd be early. The
  30–50% utilisation gains in those articles came from consolidating
  underutilised 96-CPU bare metal — on right-sized EC2 instances expect
  **no throughput gain** from SOK (SVA: "no reduction in hardware
  requirements").

## Terraform toggle design (rationale)

`deployment_model = "ec2" | "sok"` per workspace picks the build. The
**as-built layer model, the toggle flag and the exclusivity guard are owned
by the [overview](kubernetes-sok-overview.md#the-architecture-six-terraform-layers)**
(the six-layer split, `deployment_model` variable, one-live-cluster-manager
warning); `configuration.md` owns the [variable definition](configuration.md).
This study records only the design *rationale* that led there:

- **Why separate layers, not one conditional module.** A whole root module
  can't be conditionally included, and mixing EC2 and SOK resources in one
  state makes both plans noisy. Separate layers keep each state clean and let
  the shared `account`/`iam` foundation serve both paths; the SOK path adds
  `sok-foundation` (persistent S3 + KMS) + `eks` + `sok`.
- **Why the operator lives in the `sok` layer, not `eks`.** `alekc/kubectl`
  configures eagerly at plan time and cannot run in the same apply that
  creates the cluster, so the operator, CRDs and CRs must sit where the
  provider host is a concrete remote-state value. `eks` is therefore pure AWS
  infra; the operator + all Splunk CRs land in `sok`. (This is the
  as-built deviation from the plan's original K-phase sketch — see
  [plan status](kubernetes-sok-plan.md#implementation-status).)
- **Why the guard matters here.** A workspace's SmartStore bucket must only
  ever have ONE active cluster manager, so the EC2 and SOK cores are mutually
  exclusive per workspace. The enforcement lives in both paths (overview's
  toggle warning); the design consequence is that the start workflow refuses
  an `eks`/`sok` apply while cluster-layer instances exist, and vice versa.
- Version note (resolved): EKS module v21 requires **AWS provider ≥6.0**;
  the shared layers stay on `~> 5.80` and the **eks layer pins its own AWS
  provider ≥6.0** (locked to 6.54.0), so the two coexist without a repo-wide
  upgrade.
- CI (built): `sok-deploy-apps` packages each `org_*` app deterministically
  and publishes to the apps bucket, then App Framework detects it by Etag
  (EC2 keeps its push scripts). See [apps-repo-handoff](apps-repo-handoff.md).


## Validation spikes gating the prod cutover


1. **SSE-KMS + TLS overlay**: layer `remote.s3.encryption=sse-kms`,
   `kms.key_id`, `sslVerifyServerCert=true`, `sslRootCAPath` (app or
   `conf:` key) over the operator-generated SmartStore config. Pass =
   settings win, survive reconciles/bundle pushes without flapping, S3
   objects SSE-KMS with our key.
2. **Park/resume soak**: pause annotations + nodegroups→0 overnight, resume
   ×5 consecutive days. Pass = multisite reassembles, no KV-store precheck
   wedge (#1489/#1875 class), SmartStore cache reattaches.
3. **Private-PKI cert app**: CA-issued server certs on 8089/8000/9998 via
   mounted Secrets + conf app, `sslVerifyServerCert=true` on Splunk-side
   clients, **without** `requireClientCert`. Pass = operator + probes stay
   green.
4. **IRSA soak** ≥1 week of SmartStore uploads on 10.4 (the historical
   ExpiredToken bug bit at ~24h intervals; fixed 9.3.2 but soak anyway).
5. **App pipeline**: git → package → S3 → App Framework to CM/SHC/Standalone;
   confirm bundle pushes and the same-filename update flow.
6. **Destroy/recreate drill** (only if the nightly-zero model is wanted):
   full EKS teardown + morning rebuild from S3/git/Secrets Manager alone.

## Cost picture (prod-shaped, eu-west-2, July 2026)

Rates web-verified July 2026: t3.xlarge $0.1888/hr, gp3 $0.0928/GB-mo
(eu-west-2), EKS control plane **$0.10/hr ≈ $73/mo** standard support,
**$0.60/hr ≈ $438/mo** in extended support
([EKS pricing](https://aws.amazon.com/eks/pricing/),
[EBS pricing](https://aws.amazon.com/ebs/pricing/)). The authoritative
breakdown lives in [review NFR-9](reviews/non-functional.md); the
[overview](kubernetes-sok-overview.md#how-we-run-it) carries the same figures.

**Always-on SOK ≈ $750/mo** on the staged t3 shape (3× t3.xlarge ≈ $414
+ EKS control plane $73 + gp3 PVCs ≈ $225 + NLBs ≈ $37; S3 rides the free VPC
gateway endpoint, so no NAT and ~$0 SmartStore transfer). Earlier
"$490-570/mo" figures were wrong — they omitted the ~$225/mo of EBS.

| | EC2 today | SOK on EKS |
| --- | --- | --- |
| Running compute | n instances (per Infracost) | Same instance count/types as nodes (x86 only, no Spot for indexers) — **no saving**; SVA confirms same hardware needs |
| Running all-in | (≈ $833/mo always-on) | **≈ $750/mo** (compute $414 + control plane $73 + PVCs $225 + NLBs $37) |
| **STOPPED floor** (compute off, cluster kept — *pause model, unshipped*) | **~$8/mo** (no control-plane charge — the whole point of the asymmetry) | **~$73/mo control plane + retained EBS PVCs + S3** — the SOK build **avoids this state** |
| **DESTROYED floor** (`terraform destroy`, data left in place) | ~a few $/mo of S3 + KMS | **~$1-2/mo** (persistent `sok-foundation` S3 + KMS only) — where the nightly SOK stop lands |
| Version-lag penalty | — | Control plane ages into extended support → **$438/mo** on **2026-12-02** (K8s 1.34 cliff); annual K8s upgrades become mandatory, gated on SOK's release cadence (ceiling 1.34 today) |
| Migration-scoped extras | — | Apps S3 bucket (pennies), operator pod + its 10Gi PVC, NAT/LB deltas ≈ wash |

!!! note "Two rest states, not one — this is the decision criterion"
    SOK's nightly cost guard is a full `terraform destroy` of the compute
    (`sok` + `eks`, control plane included), so at rest it falls to the
    **destroyed floor ≈ $1-2/mo**, not a "$73/mo parked" floor. That $73/mo
    control-plane charge only applies to the unvalidated *pause* model
    (nodes → 0, cluster kept), which this build deliberately avoids. The
    deciding criterion is **park-capability, not raw compute**: EC2 parks
    nightly to ≈ $8/mo with no control-plane charge; SOK cannot cheaply park
    (any live EKS cluster bills $73/mo standard, $438/mo extended after
    2026-12-02), so its only cheap rest state is total destroy. That
    asymmetry — not the ~$750 vs ~$833 always-on numbers — is why prod stays
    on EC2 until the cutover.

## Open decisions

1. **Security posture**: accept operator-imposed limits — no fail-closed
   per-pod issuance, no 8089 mutual TLS, S2S TLS on 9998 — as the SOK
   security model?
2. **Edge tier**: HF/DS stay on EC2 (hybrid, the current staged choice),
   Standalone CRs with undocumented DS glue, or jump to
   IngestorCluster/SmartBus (SQS+S3, 10.2+, an architecture change — also
   where Splunk's investment is going)?

## Primary sources

- [SOK docs](https://splunk.github.io/splunk-operator/) — GettingStarted,
  [MultisiteExamples](https://github.com/splunk/splunk-operator/blob/main/docs/MultisiteExamples.md),
  [SmartStore](https://github.com/splunk/splunk-operator/blob/main/docs/SmartStore.md),
  [AppFramework](https://github.com/splunk/splunk-operator/blob/main/docs/AppFramework.md),
  [Security](https://github.com/splunk/splunk-operator/blob/main/docs/Security.md),
  [Upgrade](https://github.com/splunk/splunk-operator/blob/main/docs/SplunkOperatorUpgrade.md),
  [3.1.0 release notes](https://github.com/splunk/splunk-operator/releases/tag/3.1.0)
- [SOK Applied SVA](https://help.splunk.com/en/splunk-enterprise/splunk-validated-architectures/applied-svas/splunk-operator-for-kubernetes)
- [SmartStore on S3 security strategies (10.4)](https://help.splunk.com/en/splunk-enterprise/administer/manage-indexers-and-indexer-clusters/10.4/deploy-smartstore/smartstore-on-s3-security-strategies)
- Splunk Lantern: [initial](https://lantern.splunk.com/Platform_Data_Management/Transform_Pipelines/Splunk_Operator_for_Kubernetes:_Initial_implementation_learnings) /
  [advanced](https://lantern.splunk.com/Platform_Data_Management/Transform_Pipelines/Splunk_Operator_for_Kubernetes:_Advanced_operational_learnings)
  operational learnings
- [EKS pricing](https://aws.amazon.com/eks/pricing/) ·
  [EKS version lifecycle](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html) ·
  [EBS CSI parameters](https://github.com/kubernetes-sigs/aws-ebs-csi-driver/blob/master/docs/parameters.md)
- Load-bearing GitHub issues: [#1875](https://github.com/splunk/splunk-operator/issues/1875)
  (10.x KV-store cold-restart, open), [#1310](https://github.com/splunk/splunk-operator/issues/1310)
  (splunkd TLS mandatory for operator), [#1646](https://github.com/splunk/splunk-operator/issues/1646)
  (scaling gate), [#1652](https://github.com/splunk/splunk-operator/issues/1652)
  (label edit = rolling restart), [#1198](https://github.com/splunk/splunk-operator/issues/1198)/[#1180](https://github.com/splunk/splunk-operator/issues/1180)
  (no DS support), [#645](https://github.com/splunk/splunk-operator/issues/645)
  (no git app source), [#1250](https://github.com/splunk/splunk-operator/issues/1250)
  (IRSA token refresh, fixed 9.3.2)
