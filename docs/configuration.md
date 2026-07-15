# Configuration reference

All workspace configuration lives in
`terraform/layers/_shared/vars/<env>.tfvars` (shared into every layer via
symlinks). Variables are declared with defaults in
`terraform/layers/_shared/variables.tf`. This page covers the knobs an
operator actually turns; networking/account plumbing variables are
documented inline in `variables.tf`.

!!! note "Covers both deployment models"
    This is the single tfvars reference for the workspace, so it spans both
    the EC2 and the Kubernetes (SOK) builds. `deployment_model` picks between
    them; the SOK-only knobs (`eks_*`, `sok_*`) are grouped in the
    [SOK](#sok-splunk-operator-for-kubernetes) section at the end and only
    apply when `deployment_model = "sok"`. See the
    [SOK overview](kubernetes-sok-overview.md) for the model itself.

## Cluster topology

| Variable | Default | Purpose |
| --- | --- | --- |
| `deployment_model` | `"ec2"` | `"ec2"` = the cluster layer (ASGs + bootstrap); `"sok"` = Splunk Operator for Kubernetes (the `eks` + `sok` layers) with the EC2 core retired. Mutually exclusive per workspace (shared SmartStore bucket) — guards in both paths refuse to plan while the other model is live. See the [SOK plan](kubernetes-sok-plan.md) |
| `sok_edge_on_ec2` | `true` | Under `deployment_model = "sok"`: keep the heavy-forwarder edge tier on EC2 (SOK has no HF/DS CRD). HFs must point at the SOK S2S NLB, not indexer discovery |
| `enable_splunk_manager` / `_deployer` / `_license` / `_monitoring_console` / `_indexer` / `_searchhead` / `_forwarder` | `1` | Role on/off switches (`0`/`1`). The stop overlay (`<env>-shutdown.tfvars`) zeroes these. Under `deployment_model = "sok"` the core six are forced to 0 in the cluster layer regardless of these values |
| `enable_shc` | `true` | `true` = 3-member Search Head Cluster; `false` = standalone SH (dev) |
| `scale_splunk_indexer` | map of AZ → count | Indexers per AZ, e.g. `{ eu-west-2a = 2, eu-west-2b = 2, eu-west-2c = 0 }`. Each instance gets its own ASG and cache volume |
| `scale_splunk_searchhead` / `scale_splunk_forwarder` | map of AZ → count | Same pattern for SHs / HFs |
| `replication_factor` | `3` | Single-site RF. Under multisite this only governs **legacy non-site buckets** (e.g. bootstrapped from SmartStore before the multisite cutover) |
| `search_factor` | `2` | Single-site SF; same multisite caveat |

## Multisite

| Variable | Default | Purpose |
| --- | --- | --- |
| `multisite` | `false` | Master switch. When `true`: the CM declares `available_sites` + site factors, indexers get `[general] site` derived from their AZ (a=site1, b=site2, c=site3), SHs and HFs get `site0` (no affinity), and the CM sets `constrain_singlesite_buckets = false` so legacy buckets can meet RF across sites |
| `available_sites` | `"site1,site2"` | Comma-separated site list announced by the CM |
| `site_replication_factor_origin` | `2` | Copies required in a bucket's origin site |
| `site_replication_factor_total` | `3` | Total copies cluster-wide. With 2 sites, `origin:2,total:3` forces the third copy into the non-origin site → AZ-loss-safe |
| `site_search_factor_origin` | `1` | Searchable copies in origin site |
| `site_search_factor_total` | `2` | Total searchable copies |

!!! warning "Site capacity must fit the factors"
    `site_replication_factor` origin/total values must be satisfiable by the
    peers per site — e.g. `origin:2` needs ≥2 indexers in every site. The
    legacy-bucket single-site `replication_factor` must be ≤ total indexer
    count (it spans sites because `constrain_singlesite_buckets = false`).

## Instances & storage

| Variable | Default | Purpose |
| --- | --- | --- |
| `custom_instance_type_<role>` | per-role | Instance type per role. Splunk 10 requires AVX — beware older/burstable types in real prod (current t3a.medium fleet is the cost-minimum dev posture) |
| `use_spot` | — | Spot vs on-demand for the fleet. Burstable spot pools in eu-west-2 have drained before — see Troubleshooting |
| `indexer_cache_volume_size` | `500` (GB) | SmartStore hot/cache gp3 volume per indexer. EBS can't shrink in place — recycle indexers first to downsize |
| `data_volume_filesystem` | `"xfs"` | Filesystem for the indexer cache and HF checkpoint volumes: `"xfs"` or `"ext4"` (validated). **Applies at `mkfs` time only** — the bootstrap formats a volume only if it has no filesystem yet, so changing this never reformats existing data; recycle with fresh volumes to switch |
| `imds_http_tokens` (module) | `"required"` | IMDSv2 enforcement. Set to `"optional"` **on indexers only** — Splunk 10.4's SmartStore S3 client cannot fetch instance credentials via IMDSv2 |

## SmartStore

| Variable | Default | Purpose |
| --- | --- | --- |
| `enable_smartstore` | `1` | Creates the per-workspace S3 bucket + KMS key; the CM renders the `[volume:remote_store]` stanza into the cluster bundle |

The rendered SmartStore config (in
`terraform/modules/splunk_instance/files/bootstrap/manager.tpl`) pins:

- `remote.s3.encryption = sse-kms` with `remote.s3.kms.key_id` set to the
  workspace KMS key ARN (note: the canonical setting name is `kms.key_id` —
  the underscore form `kms_key_id` is **silently ignored** by Splunk).
- `remote.s3.sslVerifyServerCert = true` anchored to the **OS trust bundle**
  (`/etc/pki/tls/certs/ca-bundle.crt`), not the internal cluster CA — AWS
  endpoints must be verified against public roots even when cluster-internal
  TLS uses the internal PKI.

## TLS

| Variable | Default | Purpose |
| --- | --- | --- |
| `ssl_verify_server_cert` | per-env | Renders `[sslConfig] sslVerifyServerCert` on every node. When `true`, bootstrap **fails closed** if the cert-issuer Lambda is unreachable (instance exits; ASG replaces it) instead of self-signing. Prod runs `true` |
| `pki_cn_name` | — | CN of the internal root CA |

See [Security & TLS](security.md) for the full PKI flow.

## Splunk version / AMI

| Variable | Purpose |
| --- | --- |
| `splunk_ami` | AMI ID produced by the Packer build (paste after `make packer-build-splunk`) |
| `splunk_version` / `splunk_build` | Pinned Splunk release for the AMI build |

## Access & integration

| Variable | Purpose |
| --- | --- |
| `trusted_cidrs` | Operator CIDRs allowed through the `splunk-web` ALB |
| `hec_trusted_cidrs` | CIDRs allowed to the HEC endpoint |
| `apps_git_repo` | Git repo cloned at boot by CM + deployer (see [Apps & deployment](apps.md)) |
| `splunk_admin_username` | Admin account name (default `splunkadmin` — **not** `admin`) |
| `sso_admin_ad_guid` | Azure AD group GUID mapped to admin via SAML |
| `slack_alerts_channel` | Slack channel for SNS ops alerts |

## SOK (Splunk Operator for Kubernetes)

Only read when `deployment_model = "sok"`. This path uses three layers with
different lifecycles:

| Layer | Lifecycle | Holds |
| --- | --- | --- |
| `sok-foundation` | **persistent** — applied once, never in the nightly cycle | SmartStore + apps + KV-store-backup buckets + KMS key (the source of truth across nightly cycles) |
| `eks` | nightly destroy/recreate | EKS cluster, node groups, IAM/OIDC, EBS CSI, StorageClasses, ALB controller |
| `sok` | nightly destroy/recreate | Namespace, CRDs, operator, global secret, IRSA, defaults ConfigMap, Splunk CRs |

Apply order is `sok-foundation` → `eks` → `sok`; the nightly stop destroys
`sok` then `eks` (never `sok-foundation`). See the [SOK plan](kubernetes-sok-plan.md).

| Variable | Default | Purpose |
| --- | --- | --- |
| `eks_kubernetes_version` | `"1.34"` | EKS control-plane version. K8s 1.34 requires Splunk ≥10.4 (IRSA token format) and is SOK 3.1.0's ceiling; it exits standard EKS support 2026-12-02, after which a parked control plane bills 6× unless upgraded |
| `eks_vpc_name_tag` | `""` (→ `var.environment`) | `Name` tag of the `project=splunk` VPC the nodes join. Dev and prod share one account with a single VPC tagged `Name=prod`, so **dev sets this to `"prod"`**; a workspace that owns its VPC leaves it empty |
| `eks_public_access_cidrs` | `[]` (→ `trusted_cidrs`) | CIDRs allowed to the public EKS API endpoint at rest. CI appends the runner egress IP for the duration of a run |
| `eks_node_groups` | 1× `t3.xlarge` in `eu-west-2a` | Managed node groups (x86-64 only — Splunk 10 needs AVX; on-demand only for stateful indexer pods) |
| `gh_actions_role_arn` | `""` | GitHub Actions terraform role ARN (`AWS_TERRAFORM_ROLE_ARN`); granted an EKS admin access entry so CI can manage the sok layer. Empty = skip |
| `sok_namespace` | `"splunk"` | Namespace for the operator **and** all CRs — must be one namespace (a namespace-scoped operator only watches its own) |
| `sok_operator_chart_version` | `"3.1.0"` | `splunk/splunk-operator` Helm chart version. Bump together with the vendored CRDs in `sok/files/` (removed from the chart in 3.0.0) |
| `sok_splunk_image` | `docker.io/splunk/splunk:10.4.0` | Splunk Enterprise container image for all CRs (x86-64 only) |
| `sok_accept_splunk_general_terms` | `""` | Set to `"--accept-sgt-current-at-splunk-com"` to accept the [Splunk General Terms](https://www.splunk.com/en_us/legal/splunk-general-terms.html). **MANDATORY for Splunk 10.x under operator ≥3.0.0 — pods refuse to start without it.** No accepting default by design |
| `sok_indexer_replicas` | `3` | IndexerCluster peers (single-site). The operator floors this at `replication_factor` (docs: minimum 3) |
| `sok_etc_storage` / `sok_var_storage` | `10Gi` / `50Gi` | Per-pod `/opt/splunk/etc` and `/opt/splunk/var` (SmartStore cache) PVC sizes. **The operator never resizes PVCs — size generously** |

!!! note "Dev vs prod shape (multisite + SHC)"
    The sok layer is shape-aware on `multisite` + `enable_shc`. **Dev**
    (`multisite=false`, `enable_shc=false`) = 1 IndexerCluster + a Standalone SH.
    **Prod** (`multisite=true`, `enable_shc=true`) = 2 IndexerCluster CRs
    (site1=eu-west-2a / site2=eu-west-2b, per-AZ nodeAffinity) + a 3-member
    SearchHeadCluster; `sok_indexer_replicas` is counted **per site**, and the CM
    carries the multisite factors + `constrain_singlesite_buckets=false`. Prod's
    KV store is backed up to the kvbackup bucket by an in-cluster CronJob every
    6 h — restore with `make sok-kvstore-restore env=prod`.

!!! warning "SOK admin user is `admin`, not `splunkadmin`"
    The operator's REST client and bundle-push exec hardcode the literal user
    `admin`. Inside SOK the admin account is `admin` (with the shared global
    password), a deliberate divergence from the EC2 estate's `splunkadmin` —
    see [Security & TLS](security.md). Renaming it breaks all reconciliation
    (silently — splunkd 401s parse as empty results).

## The stop overlay

`terraform/layers/_shared/vars/<env>-shutdown.tfvars` zeroes every
`enable_splunk_*` flag. Applying both var-files destroys
ASGs/instances/EBS/LBs while keeping S3 data, KMS, Secrets, Route53, IAM and
ACM (~$8/mo residual). The start/stop GitHub Actions wrap exactly this —
see [Operations](operations.md).

!!! note "Off-state is config too"
    Terraform expressions that only evaluate in the stopped state (count-gated
    data sources etc.) are not exercised by normal CI — risk R16 in the
    [LLD workbook](LLD-workbook.md). When adding resources, check they plan
    cleanly under the shutdown overlay too.
