# SOK implementation plan (agent handoff)

!!! note "Historical build record"
    This is the phase-by-phase plan that built the SOK estate, written while EC2
    and SOK still co-existed behind a `deployment_model` toggle. The estate is
    now **SOK-only**: the EC2 model (the `cluster` layer, Packer, the toggle and
    its guards) is removed, and the former persistent `sok-foundation` layer is
    merged into the `account` layer. The EC2 and toggle steps below are the
    build history, not current architecture — the [overview](kubernetes-sok-overview.md)
    holds the four-layer as-built model.

Read [the design study](kubernetes-sok.md) first — this
plan assumes its findings and does not re-argue them. Every caveat marked
⚠ was verified against primary sources in June/July 2026 (and this plan was
itself adversarially reviewed against that research and this repo);
re-verify anything version-sensitive before relying on it.

**Version pins this plan was written against:** SOK **3.1.0**, Splunk
Enterprise **10.4.0**, EKS **1.34**, terraform-aws-modules/eks **v21**,
`alekc/kubectl` provider **~> 2.4**, aws-load-balancer-controller ≥2.12,
EBS CSI ≥1.30. If any of these have moved, re-check the design study's
citations first — the K8s↔Splunk version coupling below is strict.

---

## Implementation status

K1–K5 built and **verified on dev**, then torn down per the cost gate (the
persistent data layer is kept). Highlights and the deltas from this plan:

- **K1–K3 ✅ verified:** cluster + operator up, 11 CRDs, RF/SF met, ingest +
  search, and **SmartStore SSE-KMS via IRSA end-to-end** (S3 objects encrypted
  with the dev key, no static creds). **K4 ✅ verified:** apps download from S3
  via the operator's IRSA and install in `etc/apps`. **K5 ✅ code** (make
  targets, `sok-health.sh`, sok-start/stop/checks workflows, infracost); the
  nightly-cycle-×3 proof is CI work.
- **Layer deltas from the plan** (the as-built layer model is now owned by the
  [overview](kubernetes-sok-overview.md#the-architecture-four-terraform-layers)):
  the operator + CRDs live in the **`sok`** layer, not `eks` — `alekc/kubectl`
  configures eagerly at plan and cannot run in the same apply that creates the
  cluster, so it must sit where the provider host is a concrete remote-state
  value. `eks` is now pure AWS infra. The persistent SmartStore + apps +
  KV-backup buckets + KMS live in the **`account`** layer (originally split into
  a separate `sok-foundation` layer, since merged back into `account`).
- **App Framework spec field is `appRepo`** (v4), not `appFrameworkConfig`
  (older name — the v4 CRD prunes it silently).

**Open follow-ups:**

- **VPC endpoint (prod-side): ✅** — the dev
  SmartStore bucket is now in `custom_s3_bucket_access` in prod.tfvars (feeds
  only `vpc_default_ep.tf`), applied to the prod account layer, so dev SmartStore
  `PutObject` through the shared prod VPC endpoint works. App Framework reads
  never needed it (GetObject allowed on `*`).
- **MonitoringConsole** sits in `Error` (startup probe fails, pod 0/1): its
  splunkd can't authenticate to the distributed-search peers
  (`Unable to get auth token from peer: …cluster-manager-service:8089`) — a
  splunk.secret/distributed-search-auth issue, not in the data path. Deferred
  (non-critical monitoring CR).
- **CM-pod-delete / `SPLUNK_SKIP_CLUSTER_BUNDLE_PUSH`** ✅ verified: deleting the
  CM pod reboots it to Ready without rolling the indexer peer (restarts=0).
- ⚠ Force an app poll with the per-CR `splunk-<ns>-<cr>-configmap`
  `manualUpdate: on` — **never** `kubectl annotate` a CR (any metadata edit
  triggers a rolling restart, #1652).
- **Spike S0a ✅ PASS:** the operator *accepts a single indexer* (replicas=1,
  RF=1/SF=1 reached Ready, RF/SF met, indexing ready) — the docs' "minimum 3
  peers" is not enforced for a single-site cluster. So **dev runs 1 indexer on
  1 node** (see sizing below) to keep infra cost minimal.
- **Dev sizing (cost-minimised):** 1× `t3.xlarge` node (desired=1), 1 indexer,
  pod CPU requests trimmed to 250m and the operator to 100m/256Mi so the whole
  cluster + operator packs onto one node (~$0.17/hr nodes + $0.10/hr control
  plane). Prod stays small too until it's promoted (K7) — revisit sizing then.
- **Prod migration: migrate prod to SOK, multisite.** The
  prod profile is built + **staged** (behind `deployment_model=ec2` in prod.tfvars
  so the live EC2 core is untouched; inert until the gated cutover): the sok layer
  is now shape-aware on `var.multisite` — prod = 2 IndexerCluster CRs (site1/2a,
  site2/2b, per-AZ nodeAffinity, origin:2/total:3) + a 3-member SearchHeadCluster
  + `constrain_singlesite_buckets=false`; dev stays single-site + Standalone. Plus
  per-AZ eks node groups and an automated **KV-store backup/restore** (kvbackup
  foundation bucket + in-cluster CronJob + `sok-kvstore-{backup,restore}.sh`).
  Sizing is small to start (right-size before real load).
- **Dev multisite validation:** ran the prod shape (2 IndexerCluster
  CRs + 3-member SHC) on dev. **Spike S0b ✅ PASS** — the operator accepts 2
  indexers/site at origin:2 (CRs stayed replicas=2, not floored to 3), and the CM
  comes up a correct multisite manager (`available_sites`, `site_replication_factor
  origin:2,total:3`). Two fixes fell out (committed): **`multisite_master` is
  CM-only** — in the peer defaults it left peers `mode=disabled`; peers need only
  `site` (the operator gives `cluster_master_url` via `clusterManagerRef`); and
  the **operator helm timeout** (fresh-cluster PVC provisioning > 5 min default).
- **⚠ Blocker found — node-local DNS cache needed:** on the busier AZ, indexers
  crash-loop with a SmartStore FATAL (`S3ClientProps did not find credentials`)
  because `sts.<region>` DNS resolution **intermittently fails** (EKS
  CoreDNS/conntrack) → IRSA STS call fails → no S3 creds. IRSA is configured
  correctly; it's the DNS blip the plan warned of. Scaling CoreDNS isn't enough —
  the fix is the **node-local DNS cache** (plan K7.1). Full RF/SF + SmartStore +
  KV-backup validation is blocked on this.
- **Before the prod cutover:** build + validate node-local DNS cache (unblocks
  the above), then the **S1/S4** soaks (always-on window), then a supervised
  **cutover rehearsal**. **K7 prod applies stay GATED.**
- **K6 spikes S1/S3/S4** still need soak windows — not run.

---

## 0. Ground rules for the executing agent

These are repo/session conventions that override anything you'd otherwise
default to:

- **Cost gate — hard rule.** An EKS control plane bills ~$0.10/hr from the
  moment it exists. Get explicit user approval before the **first**
  `terraform apply` of the eks layer, and **destroy the eks layer at the
  end of every working session** unless told otherwise. Exception
  protocol for the soak spikes (S1/S4 need continuous days): request a
  user-approved always-on window up front, state the cost
  (~$2.40/day control plane + node hours), suppress the nightly stop for
  that window, and record it in the [LLD workbook](LLD-workbook.md).
- **One model per workspace, ever.** A SmartStore bucket must only ever
  have one live cluster manager (see the
  [overview](kubernetes-sok-overview.md#the-operator-model)). Never point a
  second cluster manager at a workspace's SmartStore bucket.
- **Prod is out of bounds** for applies unless the user explicitly asks.
  Dev-first is the standing plan. Phase K7 (prod) is design-complete but
  execution-gated on the user.
- Repo conventions: commits unsigned (`git commit --no-gpg-sign`), pushes
  over HTTPS with the PAT from Secrets Manager `/git/login`
  (`aws secretsmanager get-secret-value --secret-id /git/login` — the raw
  SecretString *is* the token; grep it out of any output). Commits are
  unsigned and carry **no** AI/Claude attribution (repo convention). Work lands
  as ordinary commits on `master` (no long-lived branch), each phase gate green
  before the next starts.
- **Admin-user divergence (decided):** the EC2 estate's admin is
  `splunkadmin`, but ⚠ the operator authenticates as the **literal user
  `admin`** — its REST client and its bundle-push exec both hardcode
  `admin:$(cat /mnt/splunk-secrets/password)` (operator source:
  `pkg/splunk/client/enterprise.go`, `pkg/splunk/enterprise/names.go`).
  **Do not rename or replace `admin` inside SOK** — every operator call
  would 401, and splunkd 401s are silent (JSON-parses as empty `entry`
  lists), so the failure is obscure: CRs never reach Ready with no useful
  error. SOK-side scripts use `admin` with the global-secret password;
  document the divergence in [security.md](security.md). If `splunkadmin`
  parity is wanted later, add it as an *additional* user via an app.
- Layer pattern: each layer has `conf/<env>.backend.conf` +
  `vars/<env>.tfvars` (symlinked to `_shared/vars/`), applied with
  `terraform workspace select -or-create <env>`. ⚠ The shared backend
  conf holds only bucket/region/encrypt — **the state key is hardcoded
  per layer in each layer's `terraform.tf`** (e.g.
  `key = "cluster/terraform.tfstate"`). New layers MUST get their own
  `terraform.tf` with unique keys (`eks/terraform.tfstate`,
  `sok/terraform.tfstate`) and their own `terraform_remote_state` data
  sources for account/iam. A verbatim copy of the cluster layer's
  `terraform.tf` would attach to the cluster state and plan the
  destruction of the EC2 estate.
- MkDocs is strict (`make docs-build` must pass); update
  [configuration.md](configuration.md) and [ci.md](ci.md) as you add
  knobs/workflows.
- Local tooling: `kubectl`, `aws`, `terraform` are present on this
  machine; **`helm` is not** — to inspect chart values, fetch the chart
  tarball from `https://splunk.github.io/splunk-operator/` (index.yaml →
  chart URL) and read `values.yaml` directly, or install helm first.

---

## 1. Target shapes

### Dev (build this first)

| CR | Spec | Notes |
| --- | --- | --- |
| ClusterManager `cm` | single-site defaults; smartstore block → dev bucket | |
| IndexerCluster `idxc` | `replicas: 3`, `clusterManagerRef: cm` | ⚠ The operator floors single-site clusters at `replication_factor` and docs state "minimum number of indexer cluster peers is 3". Dev-on-EC2 runs 1 indexer/RF1 — that shape is likely **impossible** under SOK. Start from `replicas: 3`, `idxc.replication_factor: 3`, `search_factor: 2`; spike S0 tests the smaller shapes |
| Standalone `sh` | 1 replica, `clusterManagerRef: cm` | Mirrors dev's `enable_shc=false` standalone SH |
| LicenseManager `lm`, MonitoringConsole `mc` | 1 each | Wire `licenseManagerRef`/`monitoringConsoleRef` on the other CRs |
| Nodes | 1 managed node group, eu-west-2a, 2× `t3.xlarge` (x86 — AVX required by Splunk 10) | Pods co-locate; requests small (e.g. 500m/2Gi), skip Guaranteed QoS in dev |

### Prod (phase K7, gated)

| CR | Spec | Notes |
| --- | --- | --- |
| ClusterManager `cm` | zone eu-west-2a; defaults: `site: site1`, `multisite_master: localhost`, `all_sites: site1,site2`, `multisite_replication_factor_origin: 2 / total: 3`, `multisite_search_factor_origin: 1 / total: 2`, plus `conf:` key writing `[clustering] constrain_singlesite_buckets = false` | Exact YAML skeleton is in the [design study](kubernetes-sok.md#the-m3-topology-as-sok-custom-resources) |
| IndexerCluster `idxc-site1` / `idxc-site2` | `replicas: 2` each; nodeAffinity `topology.kubernetes.io/zone In [eu-west-2a]` / `[eu-west-2b]`; defaults `site: siteN`, `multisite_master: splunk-cm-cluster-manager-service` | ⚠ **2/site is UNCONFIRMED for our factors.** The official example uses replicas:2 but with `origin:1`; `Examples.md` says multisite parts are floored at the origin count (⇒ 2 OK for origin:2), while `CustomResources.md` and issue [#1131](https://github.com/splunk/splunk-operator/issues/1131) say "minimum 3" and show the operator refusing 2/site. Spike S0b settles this **before** prod node sizing is committed — if the floor is 3/site, prod becomes 3+3 and the node plan/cost change |
| SearchHeadCluster `shc` | `replicas: 3`; defaults `site: site0` | Deployer is created by this CR (`deployerResourceSpec` available) |
| LicenseManager, MonitoringConsole | 1 each | |
| Nodes | per-AZ node groups (2a, 2b), one `m6i.2xlarge` node per indexer pod, `m6i.xlarge` class for SH/control pods; requests=limits (Guaranteed QoS); on-demand only (⚠ no Spot for stateful indexer pods — AWS + community guidance) | ⚠ This sizing is **parity with the current EC2 estate**, not SOK's documented production minimum (12 physical/24 vCPU + 12GB per indexer pod, GettingStarted.md). Deliberate deviation — record it as an LLD assumption; it matters in any Splunk-support conversation |

**Both shapes — hybrid edge:** the HF/DS edge tier stays on EC2. Under
`deployment_model = "sok"` the `cluster` layer still applies with an
edge-only flag (forwarders on, Splunk core off). ⚠ Two things break for
the retained HFs when the EC2 core disappears and MUST be handled (K3.6):
their `outputs.conf` uses **indexer discovery against the EC2 CM**
(unsupported on K8s and the CM is gone) → switch to the static NLB DNS
name on 9997; and their `[license] manager_uri` points at the EC2 LM →
default: repoint at the SOK LicenseManager exposed via an internal NLB
(single license domain); alternative (user call): keep the EC2 LM running
in the edge set and accept two license managers. **HEC stays on the EC2
HF tier in hybrid mode** — see the Route53 caveat in K3.6.

---

## 2. Phase K1 — repo plumbing

**Goal:** the toggle exists, guards exist, no AWS changes yet.

1. `_shared/variables.tf`: add
   `deployment_model` (string, default `"ec2"`, validation
   `contains(["ec2","sok"])`), and `sok_edge_on_ec2` (bool, default true —
   keeps HF/DS in the cluster layer when model is sok).
2. `cluster` layer: gate the Splunk-core enables on the model, e.g.
   `local.core_enabled = var.deployment_model == "ec2" ? 1 : 0` multiplied
   into `enable_splunk_{manager,indexer,searchhead,license,monitoring_console,deployer}`
   (license participates in the core set by default — see the hybrid-edge
   license decision above); forwarder enable survives when
   `sok_edge_on_ec2`.
3. **Skeleton `terraform/layers/sok/`** containing only backend wiring
   (own `terraform.tf`, key `sok/terraform.tfstate`, conf/vars symlinks)
   and the **exclusivity guard**: a `check` block (or `precondition` on a
   data source) that queries running EC2 instances tagged
   `project=splunk, environment=<ws>, role in (indexer, manager)` and
   fails if any exist. Mirror guard in the cluster layer's core resources
   against an EKS cluster tagged for the workspace.
4. Docs: add `deployment_model` / `sok_edge_on_ec2` rows to
   [configuration.md](configuration.md)'s knob table.

**Gate (exact commands):**

- Cluster-layer diff check: run against the vars *currently applied* — if
  the cluster is parked, include the shutdown overlay or the plan will
  show unrelated scale-up noise:
  `terraform plan -var-file=vars/dev.tfvars [-var-file=vars/dev-shutdown.tfvars] -var deployment_model=sok`
  → core resources to destroy, forwarders retained;
  same command with `-var deployment_model=ec2` → no diff.
- Guard check: with dev EC2 core instances running, `terraform plan` of
  the sok skeleton must **fail** its check; with the cluster stopped it
  must pass. The cluster-layer mirror guard passes while no EKS cluster
  exists. Do **not** apply anything.

---

## 3. Phase K2 — `terraform/layers/eks/`

**Goal:** an EKS cluster that can host SOK, fully from Terraform, cheap
and *clean* to destroy/recreate.

Own `required_providers`: ⚠ terraform-aws-modules/eks v21 requires
`hashicorp/aws >= 6.0` while the rest of the repo pins `~> 5.80` —
pin `aws ~> 6.x` **in this layer only** (separate layer = separate
lockfile). Also pin `alekc/kubectl ~> 2.4`, `hashicorp/helm`, and
`hashicorp/kubernetes` here. Do not upgrade the other layers.

Components:

1. **Cluster:** module `terraform-aws-modules/eks/aws` v21,
   `kubernetes_version = "1.34"`.
   - **Networking:** ⚠ the account layer has **no private subnets and no
     NAT** — `vpc_default.tf` creates three public subnets
     (`map_public_ip_on_launch = true`, IGW route). Decision for v1:
     **nodes go in the existing public subnets**, publicly-addressed but
     SG-restricted — matching the estate's current posture and avoiding
     ~$32/mo+ of NAT (which would also fight the nightly-destroy model).
     Note the private-subnets+NAT alternative for prod hardening in K7.
   - **API endpoint / CI access (decided, K2 deliverable):** GitHub-hosted
     runners must reach the K8s API for every sok-layer apply/destroy —
     ⚠ a private-only endpoint makes the nightly workflows impossible
     (private endpoints take no CIDR allowlist and `trusted_cidrs` is a
     single home IP). Use a **public endpoint, `authentication_mode =
     "API"`**, `public_access_cidrs = trusted_cidrs` at rest, and a
     workflow step that temporarily appends the runner's egress IP
     (`curl -s https://checkip.amazonaws.com`) via
     `aws eks update-cluster-config` before terraform touches kubernetes
     providers, removing it in an `always()` cleanup step. (Simpler
     alternative — `0.0.0.0/0` + IAM authn as the only gate — needs
     explicit user sign-off.)
   - **Access entries:** with `authentication_mode = "API"`, getting
     principals wrong locks everyone out. The module grants the *applying*
     identity admin via `enable_cluster_creator_admin_permissions = true`
     — set it. Add explicit access entries for: the GH-Actions terraform
     role (resolve the ARN: it's the repo variable `AWS_TERRAFORM_ROLE_ARN`
     — `gh variable list`) and the local operator identity
     (`aws sts get-caller-identity` under the profile used for applies).
   - ⚠ **Version treadmill:** K8s 1.34 requires Splunk ≥10.4 (IRSA token
     format) — satisfied. 1.34 exits *standard* EKS support 2026-12-02;
     SOK 3.1.0's ceiling is 1.34. Before Dec 2026 either a newer SOK must
     exist or the control plane silently bills 6× (~$438/mo). Record as a
     dated LLD risk.
   - ⚠ No EKS Auto Mode (21-day forced node recycling, per-instance
     surcharge, own EBS provisioner — all wrong for stateful indexers).
2. **Node groups:** per-AZ managed groups (shapes §1), x86_64. Custom
   launch template with `transparent_hugepage=never` + Splunk ulimits in
   user-data — ⚠ THP costs ≥30% Splunk performance and the operator does
   NOT manage node OS settings.
3. **Storage:** EBS CSI addon (IRSA role), two StorageClasses:
   `splunk-gp3-xfs` / `splunk-gp3-ext4`
   (`type: gp3`, `csi.storage.k8s.io/fstype: xfs|ext4`,
   `allowVolumeExpansion: true`, `reclaimPolicy: Delete`,
   `volumeBindingMode: WaitForFirstConsumer` — ⚠ WaitForFirstConsumer
   keeps PVs in the same AZ as zone-pinned pods; without it multisite
   pods wedge on cross-AZ volumes, SOK issue #1152). Map
   `data_volume_filesystem` to the class name.
4. **Addons via helm_release** (or eks-blueprints-addons):
   aws-load-balancer-controller, external-dns (domain filter =
   `dns_base_splunk_domain`, IRSA role).
5. **SOK CRDs + operator:**
   - ⚠ CRDs are NOT in the Helm chart (removed 3.0.0, >1MB). **Vendor**
     `splunk-operator-crds.yaml` (3.1.0 release asset) into the layer's
     `files/` with a comment recording the release URL + sha256, and
     apply via `kubectl_file_documents` + `kubectl_manifest` with
     `server_side_apply = true` (client-side apply fails on annotation
     size). ⚠ Never use `hashicorp/kubernetes`'s `kubernetes_manifest`
     for CR/CRD work — it validates at plan time and fails while CRDs
     don't exist.
   - `helm_release` of `splunk/splunk-operator` 3.1.0 (repo
     `https://splunk.github.io/splunk-operator/`), **installed into the
     same namespace the CRs will use (`splunk`)** with
     `splunkOperator.clusterWideAccess=false` — ⚠ a namespace-scoped
     operator only watches its own namespace (`WATCH_NAMESPACE`); putting
     the operator in `splunk-operator` and CRs in `splunk` leaves every
     CR Pending forever with no error. (If separate namespaces are
     wanted, find and set the chart's watch-namespace value explicitly.)
   - Chart values to verify against the chart's `values.yaml` (fetch the
     tgz — no helm CLI locally): the env-passthrough key for
     `SPLUNK_GENERAL_TERMS=--accept-sgt-current-at-splunk-com` —
     ⚠ **mandatory since 3.0.0; Splunk 10.x pods refuse to start without
     it**; confirm with the user before setting (it accepts Splunk's
     General Terms on the org's behalf) — and the operator PVC for app
     staging (⚠ without it App Framework stages downloads in RAM).
   - **Operator IRSA role** (needed by K4, created here): S3 read on the
     apps bucket + `kms:Decrypt` on its key, bound to the operator's
     ServiceAccount — ⚠ App Framework's Download phase runs in the
     *operator* pod; Splunk pods never read the apps bucket (they receive
     files via PodCopy). Keep the role in this layer so it's recreated
     with the cluster's OIDC provider each morning.
   - ⚠ `SPLUNK_SKIP_CLUSTER_BUNDLE_PUSH`: verify its default in SOK
     3.1.0 and *where it takes effect* (it affects the CM pod's
     splunk-ansible run — a CR-level env passthrough, not necessarily an
     operator-Deployment env). Goal: CM pod restarts must not trigger
     whole-cluster bundle-push rolling restarts (root cause also fixed in
     Splunk ≥9.4.4 images). Don't assume — test during K3's gate by
     deleting the CM pod and watching for peer restarts.

**Gate:** after first apply:
`aws eks update-kubeconfig --name <cluster> --region eu-west-2` (this is
the prerequisite for every kubectl below; the `make kubeconfig` wrapper
arrives in K5) → operator pod Running in `-n splunk`;
`kubectl get crds | grep -c enterprise.splunk.com` → 11; both
StorageClasses exist. Then **destroy and re-apply the whole layer once**
— destroy/recreate must be clean from day one (it is the nightly-stop
story and the DR story), including: no leftover tagged EBS volumes
(`aws ec2 describe-volumes --filters Name=tag-key,Values=kubernetes.io/cluster/<name>`)
and no leftover ELBs.

---

## 4. Phase K3 — `terraform/layers/sok/` (dev shape live)

**Goal:** the dev-shape Splunk cluster is Ready, on SmartStore, via IRSA.

1. **Namespace + global secret.** Namespace `splunk` (created by the eks
   layer's operator install; the sok layer manages resources *in* it).
   Pre-create `splunk-splunk-secret` (pattern `splunk-<ns>-secret`) via
   `kubernetes_secret` populated from Secrets Manager data sources.
   - **Source mapping (explicit):** `password` ←
     `/monitoring/splunk/password`; `pass4SymmKey`, `idxc_secret`,
     `shc_secret` ← `/splunk/pass4SymmKey` (the EC2 estate uses one
     shared key for both cluster and SHC — keep that for bucket/config
     compatibility); `hec_token` ← create a new dedicated secret
     `/splunk/hec/sok-<env>` (don't reuse `/splunk/hec/aws-events` — it
     belongs to the cluster layer's Lambda wiring).
   - ⚠ **Exact key names** (operator source — the PasswordManagement
     prose is wrong): `password`, `pass4SymmKey`, `idxc_secret`,
     `shc_secret`, `hec_token`. A mistyped key is silently replaced by an
     operator-generated value.
   - ⚠ The operator back-fills empty keys and adds ownerReferences —
     don't fight it with a reconciling controller (no External Secrets
     Operator in v1; Terraform-managed with `ignore_changes` on metadata
     is fine).
2. **Defaults ConfigMaps.** One per CR kind, mounted via `defaultsUrl`.
   ⚠ Never use inline `spec.defaults` for anything you might edit —
   every inline edit triggers a full rolling recycle of that CR's pods;
   `defaultsUrl` + ConfigMap lets you stage changes and control when pods
   roll. (Reference for available keys:
   [splunk-ansible default.yml.spec](https://github.com/splunk/splunk-ansible/blob/develop/docs/advanced/default.yml.spec.md).)
3. **IRSA for SmartStore.** ServiceAccount `splunk-idx` annotated with an
   IAM role (created in this layer — recreated with the cluster's OIDC
   provider nightly, never hand-pasted) whose policy matches the EC2
   indexer role's SmartStore statements (S3
   Get/Put/Delete/List/AbortMultipart on the workspace bucket +
   `kms:Decrypt/GenerateDataKey/DescribeKey`). Set `spec.serviceAccount`
   on ClusterManager + IndexerCluster CRs, **no `secretRef`** in the
   smartstore volume. The Standalone SH needs no S3 role in dev.
   - ⚠ `AWS_STS_REGIONAL_ENDPOINTS=regional` required — EKS's webhook
     injects it; assert its presence in the pod env at the gate. The
     projected token needs the operator's default `fsGroup 41812` — don't
     override securityContext.
   - ⚠ EKS **Pod Identity** is NOT confirmed to work with splunkd — stay
     on IRSA.
4. **CRs** via `kubectl_manifest` (templatefile-rendered YAML — reuse the
   repo's `.tpl` idiom), dev shape from §1.
   - ⚠ **No `splunk-enterprise` Helm chart / `sva.m4` preset** — it
     hardcodes wrong RF/SF and silently ignores `defaults` on
     CM/IndexerClusters.
   - Omit the `enterprise.splunk.com/delete-pvc` finalizer (PVCs survive
     CR deletion; the STOP workflow deletes them *explicitly* — K5.4 —
     so nothing leaks).
   - SmartStore block on the ClusterManager CR (dev bucket, no
     secretRef); `varVolumeStorageConfig`: dev 50Gi; prod ~700Gi on
     `splunk-gp3-xfs` — ⚠ **size generously: the operator never resizes
     PVCs** (#558 won't-fix; manual workaround = expand PVC +
     orphan-delete the StatefulSet).
   - Probe overrides on indexer CRs from day one (Lantern): startupProbe
     `failureThreshold: 40`, livenessProbe `failureThreshold: 30` (CM:
     14) — ⚠ default probes kill busy indexers mid-load and
     mid-KV-store-migration → unclean shutdown → SmartStore
     bucket-corruption risk.
   - preStop hook (`splunk offline || splunk stop`) via the CR pod
     template if exposed; if not, note the gap and set
     `terminationGracePeriodSeconds ≥ 600` on indexers.
   - Create PodDisruptionBudgets yourself (operator makes none):
     `minAvailable: 1` per site's indexers, `minAvailable: 2` for SHC
     (prod).
5. **SSE-KMS + TLS overlay** (spike S1 makes this permanent). Overlay
   `indexes.conf`:

   ```ini
   [volume:<operator-volume-name>]
   remote.s3.encryption = sse-kms
   remote.s3.kms.key_id = <workspace KMS key ARN>
   remote.s3.sslVerifyServerCert = true
   remote.s3.sslRootCAPath = /etc/pki/tls/certs/ca-bundle.crt
   remote.s3.kms.sslVerifyServerCert = true
   remote.s3.kms.sslRootCAPath = /etc/pki/tls/certs/ca-bundle.crt
   ```

   Discover the operator-generated volume stanza name first:
   `kubectl exec <indexer-pod> -- /opt/splunk/bin/splunk btool indexes list --debug | grep 'volume:'`.
   Two delivery routes with **different precedence layers**: the defaults
   `conf:` key (→ `etc/system/local`, available now) vs an App Framework
   app on the CM (→ cluster bundle, available after K4). **S1 runs twice**
   — S1a on the `conf:` route to gate K3, S1b re-run after switching to
   the app route in K4; only then is the caveat closed. ⚠ The CA-bundle
   path is valid in the UBI9 `splunk/splunk` image. ⚠ `remote.s3.kms.key_id`
   with the dot — the underscore form is silently ignored (same trap as
   EC2).
6. **Ingress + hybrid-edge wiring:**
   - Splunk Web: ALB via LB-controller Ingress → SH service 8000, Splunk
     Web SSL enabled in pod defaults so the ALB target protocol is HTTPS
     — ⚠ SOK's matrix forbids termination-only for Web/REST (backend
     must be TLS); sticky sessions required or users get blank pages.
   - S2S: Service type LoadBalancer (internal NLB, ip targets) → indexer
     service 9997. ⚠ SOK configures 9997 as a **non-SSL** listener; TLS
     S2S later rides 9998 (spike S3). NLB must resolve ≥2 IPs to preserve
     forwarder auto-LB.
   - **Route53 names:** external-dns claims `search.` and `mc.` (their
     EC2 records are core-gated and vanish in sok mode). ⚠ **Do NOT
     claim `hec.`** — `aws_route53_record.hec_web` is gated on
     `enable_splunk_forwarder`, which stays 1 in hybrid mode: the record
     remains Terraform-owned and pointing at the EC2 HF tier. HEC
     ingestion stays on the EC2 HFs in v1; if a K8s-side HEC is wanted,
     publish it as `hec-k8s.<domain>`.
   - **Retained-HF repoint (must ship with the sok cutover, not after):**
     an edge-mode variant of the HF bootstrap/outputs config —
     `outputs.conf` switches from indexer discovery to the static S2S NLB
     name:9997, and `[license] manager_uri` repoints to the SOK
     LicenseManager exposed via an internal NLB on 8089 (dedicated name,
     e.g. `license-k8s.<internal>`; SG: HF SG → node SG on the target
     port). Alternative (user decision): keep the EC2 LM in the edge set
     instead.
7. **TLS posture v1 (explicit, decided):** splunkd 8089 keeps Splunk's
   self-signed certs; `sslVerifyServerCert` stays **false** inside the
   cluster. A deliberate, documented regression vs EC2 (note it in
   [security.md](security.md)) until spike S3 lands the private-PKI cert
   app. ⚠ Never enable `requireClientCert` on 8089 (operator presents no
   client cert; probes curl 8089 — either breaks reconciliation). ⚠ Never
   disable splunkd TLS either (operator hardcodes https — issue #1310).

**Gate:** all CRs `Phase: Ready`
(`kubectl get clustermanager,indexercluster,standalone,licensemanager,monitoringconsole -n splunk`);
`splunk show cluster-status` via `kubectl exec` (auth `admin`, password
read *inside* the pod from `/mnt/splunk-secrets/password`) shows RF/SF
met; test event ingested and searchable; fresh S3 upload shows
`ServerSideEncryption: aws:kms` with the workspace key
(`aws s3api head-object`); indexer pod env contains
`AWS_WEB_IDENTITY_TOKEN_FILE` + `AWS_STS_REGIONAL_ENDPOINTS=regional` and
no `s3_access_key` secret exists; CM-pod-delete test does **not** roll
the peers (the `SPLUNK_SKIP_CLUSTER_BUNDLE_PUSH` verification from K2).

---

## 5. Phase K4 — app pipeline (git → S3 → App Framework)

**Goal:** the `org_*` apps deploy to SOK tiers with the same one-command
UX as EC2.

⚠ **The apps live in a separate repo** (`apps_git_repo` in tfvars →
`github.com/livehybrid/splunk-apps.git`; on EC2 they're cloned
on-instance). Nothing in this repo's checkout contains the app dirs — the
packaging step must clone that repo first (PAT from `/git/login`, same
convention; NO Claude attribution on any commits to the apps repo).

1. Account layer: apps bucket `…-splunk-apps-<env>` (private, SSE-KMS
   with the workspace key). Bucket lives in the long-lived account layer;
   the **read-side grants live on the operator's IRSA role in the eks
   layer** (recreated nightly) — ⚠ only the operator pod reads this
   bucket (Download phase); Splunk pods receive apps via PodCopy. Write
   access: the GH-Actions role.
2. `scripts/package-apps.sh <env> <scope>`: clone/refresh `apps_git_repo`
   into a workdir, then for each app dir
   `COPYFILE_DISABLE=1 tar -czf org_<app>.tgz org_<app>/` and
   `aws s3 cp` into per-scope prefixes (`idx-apps/`, `shc-apps/`,
   `sh-apps/`, `cm-apps/`).
   - ⚠ **Stable archive filenames forever** — change detection is
     Etag-keyed by filename; renaming breaks upgrade tracking (#1105).
     Never embed versions in filenames.
   - ⚠ Deleting an archive does NOT uninstall the app (#893) — retire an
     app by shipping a final version with `state = disabled` in app.conf;
     document the manual cleanup.
3. `appRepo` on the CRs: indexer apps on the **ClusterManager** CR
   (⚠ IndexerCluster CRs take no appRepo), SHC apps on the
   SearchHeadCluster CR, Standalone/LM/MC take `local` scope only.
   **Trigger model (decided): polling-only** —
   `appsRepoPollIntervalSeconds: 600` on every appRepo (⚠ unset/0 means
   polling *disabled*, the "default 3600" in the API comment is not
   actually injected; and all CRs of a kind in the namespace must have
   polling uniformly on or off). The workflow uploads, then polls CR
   `status.appContext` until installed. The namespace-level manual
   trigger exists as an optional accelerator — exact invocation (note:
   this is the *namespace* ConfigMap; a separate per-CR
   `splunk-<ns>-<cr>-configmap` with `manualUpdate: "true"` exists too):

   ```sh
   kubectl patch cm splunk-splunk-manual-app-update -n splunk \
     --type merge -p '{"data":{"ClusterManager":"status: on\nrefCount: 1"}}'
   ```

4. `deploy-apps` workflow/make target grows a `sok` branch: package →
   upload → poll status.
   - ⚠ Local-scope installs do **not** restart pods (#1402) — for
     Standalone/MC apps needing restarts, follow with
     `kubectl exec … splunk restart`.
   - ⚠ A broken app wedges the pipeline with no timeout, and a fixed
     re-upload under the same name is ignored while "in progress"
     (#1480) — workaround: change a byte so the Etag changes, or
     delete/recreate the appSource entry.
5. Re-run spike **S1b** (SSE-KMS overlay via the app route) and close the
   overlay caveat only if it passes.

**Gate:** an `org_*` app lands on the SH; CM pushes cluster bundle
(`splunk show cluster-bundle-status`); a second upload of a modified
archive rolls out without manual pod deletion; S1b churn test green.

---

## 6. Phase K5 — ops parity (make, workflows, checks, stop)

1. **Make targets:** `kubeconfig env=<env>`, `kexec env=<env> role=<cr>`,
   `sok-status env=<env>` (`kubectl get` across CRs). Names/UX parallel
   to `ssm`/`status`.
2. **Health:** `scripts/sok-health.sh <env>` mirroring
   `cluster-health.sh`: CR phases Ready + the same REST checks
   (cluster-status RF/SF, kvstore-status, license) via `kubectl exec` —
   auth as **`admin`** with the password read *inside* the pod from
   `/mnt/splunk-secrets/password` (never on the command line). Assert the
   `entry` key exists (silent-401 trap). Port `rf-remediate.sh`: same
   fixup-signature detection; remedy = `splunk rolling-restart
   cluster-peers` via exec on the CM pod.
3. **Checks workflow:** branch on `deployment_model`; same 12×120s retry
   envelope.
4. **Start/stop workflows** for `sok` workspaces:
   - START = apply `eks` then `sok` (cluster layer edge-only apply
     unchanged). Expect ~20–25 min wall clock.
   - STOP (nightly cost guard) = the **destroy/recreate model** — the
     only route to ~$0 overnight. Ordered steps, each of which matters:
     1. *Hot-bucket roll (data-loss guard):* for each indexer pod, roll
        hot buckets so they upload to S3 before the PVCs die. ⚠ The
        exact invocation must be validated during a **supervised** stop
        before it's trusted in the 21:30 cron — iterate indexes
        explicitly (enumerate via REST `/services/data/indexes`, then
        POST `/services/data/indexes/<name>/roll-hot-buckets` per index;
        do **not** assume a `-` wildcard form works), then allow the
        cache manager a drain window and check upload queues are empty.
     2. *Destroy `sok` layer* (CRs + Services/Ingress go — this frees the
        LB-controller-created NLB/ALBs before the eks layer needs the
        subnets/SGs clean).
     3. *Delete the `splunk` namespace / all PVCs and wait* — ⚠ PVC
        deletion must happen **while the CSI driver still exists** so
        `reclaimPolicy: Delete` actually deletes the EBS volumes;
        deleting the cluster first orphans them and they bill nightly.
     4. *Destroy `eks` layer* (with one retry, mirroring the EC2 stop's
        retry pattern).
     5. *Verify:* extend the stop workflow's verify step beyond
        `aws eks list-clusters` — also
        `aws ec2 describe-volumes --filters Name=tag-key,Values=kubernetes.io/cluster/<name>`
        and `aws elbv2 describe-load-balancers` must come back empty.
   - Accepted consequences (dev): KV-store content is disposable
     (nothing depends on it in dev — say so in the run summary); source
     of truth is S3 + git + Secrets Manager.
   - ⚠ **KV-store cold-start wedge** (#1489 closed *without* a public
     fix; #1875 open): field reports are from **retained-PVC** restarts;
     fresh-PVC morning starts are *expected* to avoid it but this is
     unverified — exactly what the nightly cycle will establish.
     Workaround ladder: (1) the K3 probe overrides give pods a ~20-min
     startup budget, (2) if a pod wedges, delete its var PVC + pod
     (disposable state), (3) log every occurrence — the frequency data
     feeds the prod go/no-go.
   - ⚠ The existing 21:30 UTC scheduled stop **only targets prod**
     (`TARGET_ENV: inputs.env || 'prod'`) — extend the schedule to also
     stop the dev eks/sok layers (env matrix or second job), or the cost
     gate has no automated backstop.
5. **Infracost:** add both layers to `infracost.yml` projects.

**Gate:** full nightly cycle proven ×3 in dev: STOP leaves zero
EKS/EC2/EBS/ELB cost (per the extended verify step), START next morning
reaches all-Ready + checks green unattended.

---

## 7. Phase K6 — validation spikes (dev, before any prod talk)

Run as controlled experiments; record results in the
[LLD workbook](LLD-workbook.md). S0b/S1/S4 results are prod go/no-go
inputs. S1 (48h) and S4 (≥7 days) need the **always-on exception window**
from §0 — get it approved before starting them; a soak silently reset by
the nightly destroy is an invalid result.

| # | Spike | Procedure | Pass |
| --- | --- | --- | --- |
| S0a | Dev min-shape | Try `IndexerCluster replicas: 1` + RF/SF 1 | Operator accepts & Ready; else lock dev at 3 peers |
| S0b | **Prod multisite floor** | Deploy the 2-site shape in dev: 2 IndexerCluster CRs, `replicas: 2` each, `origin:2,total:3` | Operator accepts 2/site and reaches Ready (settles the #1131-vs-Examples.md conflict); if floored to 3/site, re-cost prod (§1) before K7 |
| S1a/b | **SSE-KMS overlay** | K3.5 overlay live; churn test: edit CM CR labels (forces roll), push an unrelated bundle, restart operator; watch btool output + S3 object encryption over 48h. Run on the `conf:` route (S1a, gates K3) and again on the app route (S1b, gates K4) | Settings win every time, no flapping, all new uploads SSE-KMS with our key |
| S2 | Park/resume (only if the pause-model is ever wanted; skip if destroy/recreate stays accepted) | Pause annotations on all CRs → nodegroups to 0 → overnight → resume, ×5 days | Multisite reassembles unaided; no KV wedge; cache PVCs reattach |
| S3 | **Private-PKI cert app** | Issue certs from the existing Lambda CA out-of-band (extend `cert_issuer` allowed suffixes to pod DNS names); mount via K8s Secret + CR volumes; app sets `serverCert`/`sslRootCAPath` on 8089/8000 + a TLS S2S listener on 9998; `sslVerifyServerCert=true` on Splunk-side clients only | Operator + probes stay green (they skip verify); splunk-to-splunk verified TLS; **requireClientCert stays off** |
| S4 | **IRSA soak** | ≥7 continuous days of SmartStore uploads on 10.4 (needs the exception window) | Zero `ExpiredToken`/STS errors (historical bug bit at ~24h; fixed 9.3.2 — confirm on 10.4) |
| S5 | App-pipeline edge cases | Same-name re-upload, wedged-app recovery (Etag bump), local-scope restart handling | Documented runbook entries for each |
| S6 | Destroy/recreate drill | Falls out of K5's nightly cycle — formalise: 5 consecutive cycles with checks green | ≥4/5 unattended-green; every failure root-caused |


---

## 9. Consolidated caveat/workaround register

Quick-reference; each ⚠ above appears here with its disposition.

| Caveat | Impact | Workaround / disposition |
| --- | --- | --- |
| Operator authenticates as literal `admin` | renaming admin breaks all reconciliation, silently | keep `admin` in SOK; scripts adapt; divergence documented (§0) |
| Namespace-scoped operator watches only its own ns | CRs Pending forever, no error | operator installed into ns `splunk` with the CRs (K2.5) |
| GH runners must reach the K8s API nightly | private endpoint = nightly stop impossible | public endpoint + API auth mode + temporary runner-CIDR step (K2.1) |
| Account VPC has no private subnets/NAT | "use private subnets" unfollowable | nodes in existing public subnets, SG-restricted; NAT alternative noted for prod (K2.1) |
| Per-layer hardcoded state keys | copied terraform.tf attaches to cluster state → plans EC2 destruction | unique keys `eks/`, `sok/` + own remote-state data sources (§0) |
| CRDs not in Helm chart (3.0.0+) | install breaks if assumed | vendored CRDs yaml, kubectl provider, server-side apply (K2.5) |
| `SPLUNK_GENERAL_TERMS` required for 10.x | pods never start | chart env passthrough (verify key in values.yaml); user sign-off (K2.5) |
| `kubernetes_manifest` plan-time CRD validation | TF can't manage CRs | `alekc/kubectl ~> 2.4` throughout (K2/K3) |
| Helm `sva.m4` hardcodes RF/SF, ignores defaults | silently wrong cluster | raw CRs only (K3.4) |
| Inline `spec.defaults` edits → full rolling recycle | surprise restarts | `defaultsUrl` ConfigMaps only (K3.2) |
| Global-secret key names wrong in docs prose | silent credential mismatch | `password/pass4SymmKey/idxc_secret/shc_secret/hec_token`; sources mapped in K3.1 |
| SmartStore CR can't express SSE-KMS/TLS | uploads not encrypted with our key | overlay app; S1a (conf route) + S1b (app route) validate precedence (K3.5, K4.5) |
| `kms_key_id` underscore form silently ignored | KMS setting no-ops | dot form `remote.s3.kms.key_id` (K3.5) |
| IRSA needs regional STS + fsGroup 41812; Pod Identity unproven | auth failures | assert env at gate; stay on IRSA (K3.3) |
| Historical IRSA token-refresh failure (≤9.3.1) | SmartStore dies ~24h | fixed 9.3.2+; S4 soak confirms on 10.4 |
| Single-site floor "min 3 peers"; **2/site at origin:2 unconfirmed** (#1131 vs Examples.md) | dev RF1 shape and prod 2+2 sizing both at risk | spikes S0a/S0b before shapes are committed |
| PVCs never resized by operator | cache exhaustion | size up front; manual expand + orphan-delete STS (K3.4) |
| Default probes kill busy/migrating pods | unclean shutdown, bucket corruption | raised thresholds + custom probes day one (K3.4) |
| Any CR label/annotation edit → rolling restart (#1652) | ops friction | batch CR metadata changes into maintenance windows |
| One un-Ready pod blocks all scaling (#1646) | stuck operations | fix pod first; last resort operator restart / manual STS edit |
| No downgrades (operator or Splunk image) | one-way upgrades | PVC-level snapshots before upgrades (velero, later) |
| App Framework: S3 only, Etag+filename tracking, no uninstall, no local-restart, wedge-on-bad-app | app ops differ from git flow | K4 pipeline rules + S5 runbook |
| Apps monorepo is a separate git repo | packaging step has nothing to package | clone `apps_git_repo` with `/git/login` PAT first (K4) |
| Only the operator pod reads the apps bucket | misdirected IAM debugging | grants on operator IRSA role only; pods get apps via PodCopy (K2.5/K4.1) |
| Indexer apps only via CM CR | misplaced appRepo silently useless | K4.3 |
| Poll-interval unset = polling disabled; uniform per kind | "default 3600" assumption breaks updates | explicit 600s everywhere; namespace manual trigger as accelerator (K4.3) |
| No DS CRD / no deployment-apps delivery / no UF image support | external fleet unmanaged | edge tier stays EC2 (hybrid) — standing decision |
| Retained HFs depend on EC2 CM discovery + LM | hybrid edge silently broken | outputs → static NLB; license → SOK LM via internal NLB (or keep EC2 LM — user call) (K3.6) |
| `hec.` Route53 record is forwarder-gated, not core-gated | external-dns collision with Terraform-owned record | HEC stays on EC2 HFs; K8s HEC under a new name if needed (K3.6) |
| Indexer discovery unsupported on K8s | forwarder cutover touches every outputs.conf | static NLB endpoint (K3.6, K7.3) |
| 9997 is non-SSL in SOK; Web/REST need end-to-end TLS; sticky sessions required | ingress design constraints | K3.6/K3.7; TLS S2S on 9998 via S3 spike |
| `requireClientCert` breaks operator; disabling splunkd TLS breaks operator (#1310) | security posture ceiling | documented regression; S3 spike defines the ceiling |
| cert-manager integration doesn't exist (PR #1460 closed; #1596 draft) | no auto cert lifecycle | out-of-band issuance from existing Lambda CA (S3); watch #1596 |
| KV-store cold-restart wedge on 10.x (#1489 closed unfixed; #1875 open) — field-reported on **retained-PVC** restarts; fresh-PVC behaviour unverified | park/start failures | probe budget, disposable-PVC ladder, frequency tracking (K5.4) |
| CM restart used to trigger bundle-push restarts | surprise cluster roll | verify `SPLUNK_SKIP_CLUSTER_BUNDLE_PUSH` default + effect point in 3.1.0; CM-pod-delete test in K3 gate |
| Hot-bucket roll endpoint: wildcard form unverified | 2am data-loss guard silently no-ops | per-index iteration; supervised validation before cron (K5.4) |
| PVC deletion ordering vs CSI driver | orphaned EBS volumes billing nightly | delete ns/PVCs **before** eks destroy; volume+ELB checks in verify (K5.4) |
| Scheduled stop targets prod only | dev EKS never auto-stopped | extend schedule to dev once layers exist (K5.4) |
| Same-bucket reattach by a new SOK cluster is undocumented | cutover risk | dev rehearsal is the validation; baseline queries + rollback mandatory (K7.3) |
| EC2 stop workflow doesn't roll hot buckets | cutover data loss | SSM pre-stop roll before teardown (K7.3.1) |
| EKS floor $73/mo, $438/mo extended; 1.34 standard ends 2026-12-02; SOK ceiling = 1.34 | cost + version treadmill | nightly full destroy (dev); dated LLD risk; track SOK releases (K2.1) |
| Auto Mode / Spot unsuitable for indexers | node design | per-AZ managed on-demand groups (K2.2) |
| THP + ulimits are node-level, not operator-managed | ≥30% perf loss | launch-template user-data (K2.2) |
| PV/pod AZ mismatch in multisite (#1152) | pods unschedulable | `WaitForFirstConsumer` on StorageClasses (K2.3) |
| DNS blip can wedge CM below RF/SF | prod stability | node-local DNS cache (K7.1) |
| No PDBs from operator | voluntary-disruption risk | create own PDBs (K3.4) |
| AWS provider v6 required by EKS module v21 vs repo's v5.80 | provider conflict | per-layer provider pinning (K2) |
| Indexer pod sizing below SOK's documented production minimum | support-conversation exposure | deliberate EC2-parity deviation, logged as LLD assumption (§1) |

## 10. Execution order & sizing

K1 → K2 → K3 → K4 → K5 strictly sequential; S0a/S0b/S1a inside K3's gate
window; S4 starts once K3 gates (needs the exception window) and runs in
the background; S5 + S1b inside K4; S6 falls out of K5.

Estimates split **effort vs elapsed** (elapsed includes soak windows and
the ~20–25 min/session teardown-rebuild tax the cost gate imposes):

| Phase | Effort | Elapsed |
| --- | --- | --- |
| K1 | ~half a day | same |
| K2 | 1–2 days (iteration on operator install + destroy-cleanliness) | 2 days |
| K3 | 2–3 days (SmartStore overlay is the fiddly part) | ≥3–4 days (S1a 48h churn inside the gate) |
| K4 | 1–2 days | 2–3 days (S1b re-churn) |
| K5 | 1–2 days | ≥4 days (×3 proven nightly cycles) |
| K6 remainder (S3, S4 window) | 1–2 days | 7–10 days (S4 soak) |
