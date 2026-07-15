# Configuration reference

All workspace configuration lives in
`terraform/layers/_shared/vars/<env>.tfvars` (shared into every layer via
symlinks). Variables are declared with defaults in
`terraform/layers/_shared/variables.tf`. This page covers the knobs an operator
actually turns; networking/account plumbing variables are documented inline in
`variables.tf`. See the [SOK overview](kubernetes-sok-overview.md) for the model
itself.

## Cluster topology

| Variable | Default | Purpose |
| --- | --- | --- |
| `enable_shc` | `true` | `true` = 3-member Search Head Cluster; `false` = standalone SH (dev) |
| `replication_factor` | `3` | Single-site RF. Under multisite this only governs **legacy non-site buckets** (e.g. bootstrapped from SmartStore before the multisite cutover) |
| `search_factor` | `2` | Single-site SF; same multisite caveat |

## Multisite

| Variable | Default | Purpose |
| --- | --- | --- |
| `multisite` | `false` | Master switch. When `true`: the CM declares `available_sites` + site factors, indexers get `[general] site` derived from their AZ (a=site1, b=site2, c=site3), SHs get `site0` (no affinity), and the CM sets `constrain_singlesite_buckets = false` so legacy buckets can meet RF across sites |
| `available_sites` | `"site1,site2"` | Comma-separated site list announced by the CM |
| `site_replication_factor_origin` | `2` | Copies required in a bucket's origin site |
| `site_replication_factor_total` | `3` | Total copies cluster-wide. With 2 sites, `origin:2,total:3` forces the third copy into the non-origin site → AZ-loss-safe |
| `site_search_factor_origin` | `1` | Searchable copies in origin site |
| `site_search_factor_total` | `2` | Total searchable copies |

!!! warning "Site capacity must fit the factors"
    `site_replication_factor` origin/total values must be satisfiable by the
    peers per site, e.g. `origin:2` needs ≥2 indexers in every site. The
    legacy-bucket single-site `replication_factor` must be ≤ total indexer
    count (it spans sites because `constrain_singlesite_buckets = false`).

## Storage

| Variable | Default | Purpose |
| --- | --- | --- |
| `data_volume_filesystem` | `"xfs"` | Filesystem for the indexer var (SmartStore cache) volumes: `"xfs"` or `"ext4"` (validated). Maps 1:1 onto the EBS-CSI StorageClass `csi.storage.k8s.io/fstype` (`splunk-gp3-xfs` / `splunk-gp3-ext4`). **Applies at volume-provision time only** (the operator never reformats existing PVCs), so switching means recycling with fresh volumes |

## SmartStore

| Variable | Default | Purpose |
| --- | --- | --- |
| `enable_smartstore` | `1` | Creates the per-workspace SmartStore S3 bucket + KMS key (in the `account` layer); the CM renders the SmartStore config pushed to peers |

The SSE-KMS overlay pins:

- `remote.s3.encryption = sse-kms` with `remote.s3.kms.key_id` set to the
  workspace KMS key ARN (note: the canonical setting name is `kms.key_id`;
  the underscore form `kms_key_id` is **silently ignored** by Splunk).
- `remote.s3.sslVerifyServerCert = true` anchored to the **OS trust bundle**
  (`/etc/pki/tls/certs/ca-bundle.crt`), not any internal cluster CA: AWS
  endpoints must be verified against public roots.

## Access & integration

| Variable | Purpose |
| --- | --- |
| `trusted_cidrs` | Operator CIDRs allowed through the external web ALB and the EKS public API endpoint |
| `hec_trusted_cidrs` | CIDRs allowed to the HEC endpoint |
| `apps_git_repo` | Git repo packaged to S3 for App Framework (see [Apps & deployment](apps.md)) |
| `slack_alerts_channel` | Slack channel for SNS ops alerts |

## SOK (Splunk Operator for Kubernetes)

The SOK path uses two disposable compute layers on top of the persistent
`account` layer:

| Layer | Lifecycle | Holds |
| --- | --- | --- |
| `account` | **persistent**, applied once, holds the source of truth across cycles | SmartStore + apps + KV-store-backup buckets + KMS key, the HEC-token secret |
| `eks` | nightly destroy/recreate | EKS cluster, node groups, IAM/OIDC, EBS CSI, StorageClasses, ALB controller |
| `sok` | nightly destroy/recreate | Namespace, CRDs, operator, global secret, IRSA, defaults ConfigMap, Splunk CRs |

Apply order is `account` → `iam` → `eks` → `sok`; the nightly stop destroys
`sok` then `eks` (never `account`). See the [SOK plan](kubernetes-sok-plan.md).

| Variable | Default | Purpose |
| --- | --- | --- |
| `eks_kubernetes_version` | `"1.34"` | EKS control-plane version. K8s 1.34 requires Splunk ≥10.4 (IRSA token format) and is SOK 3.1.0's ceiling; it exits standard EKS support 2026-12-02, after which a parked control plane bills 6× unless upgraded |
| `eks_vpc_name_tag` | `""` (→ `var.environment`) | `Name` tag of the `project=splunk` VPC the nodes join. Dev and prod share one account with a single VPC tagged `Name=prod`, so **dev sets this to `"prod"`**; a workspace that owns its VPC leaves it empty |
| `eks_public_access_cidrs` | `[]` (→ `trusted_cidrs`) | CIDRs allowed to the public EKS API endpoint at rest. CI appends the runner egress IP for the duration of a run |
| `eks_node_groups` | 1× `t3.xlarge` in `eu-west-2a` | Managed node groups (x86-64 only, Splunk 10 needs AVX; on-demand only for stateful indexer pods) |
| `gh_actions_role_arn` | `""` | GitHub Actions terraform role ARN (`AWS_TERRAFORM_ROLE_ARN`); granted an EKS admin access entry so CI can manage the sok layer. Empty = skip |
| `sok_namespace` | `"splunk"` | Namespace for the operator **and** all CRs, must be one namespace (a namespace-scoped operator only watches its own) |
| `sok_operator_chart_version` | `"3.1.0"` | `splunk/splunk-operator` Helm chart version. Bump together with the vendored CRDs in `sok/files/` (removed from the chart in 3.0.0) |
| `sok_splunk_image` | `docker.io/splunk/splunk:10.4.0` | Splunk Enterprise container image for all CRs (x86-64 only) |
| `sok_accept_splunk_general_terms` | `""` | Set to `"--accept-sgt-current-at-splunk-com"` to accept the [Splunk General Terms](https://www.splunk.com/en_us/legal/splunk-general-terms.html). **MANDATORY for Splunk 10.x under operator ≥3.0.0, pods refuse to start without it.** No accepting default by design |
| `sok_indexer_replicas` | `3` | IndexerCluster peers (single-site). The operator floors this at `replication_factor` (docs: minimum 3) |
| `sok_etc_storage` / `sok_var_storage` | `10Gi` / `50Gi` | Per-pod `/opt/splunk/etc` and `/opt/splunk/var` (SmartStore cache) PVC sizes. **The operator never resizes PVCs, size generously** |

!!! note "Dev vs prod shape (multisite + SHC)"
    The sok layer is shape-aware on `multisite` + `enable_shc`. **Dev**
    (`multisite=false`, `enable_shc=false`) = 1 IndexerCluster + a Standalone SH.
    **Prod** (`multisite=true`, `enable_shc=true`) = 2 IndexerCluster CRs
    (site1=eu-west-2a / site2=eu-west-2b, per-AZ nodeAffinity) + a 3-member
    SearchHeadCluster; `sok_indexer_replicas` is counted **per site**, and the CM
    carries the multisite factors + `constrain_singlesite_buckets=false`. Prod's
    KV store is backed up to the kvbackup bucket by an in-cluster CronJob every
    6 h, restore with `make sok-kvstore-restore env=prod`.

!!! warning "SOK admin user is `admin`, not `splunkadmin`"
    The operator's REST client and bundle-push exec hardcode the literal user
    `admin`. Inside SOK the admin account is `admin` (with the shared global
    password). Renaming it breaks all reconciliation, silently (splunkd 401s
    parse as empty results). See [Security & TLS](security.md).

## External web / HEC

The opt-in external ALB and its DNS knobs are documented in the
[SOK overview](kubernetes-sok-overview.md#external-access-splunk-web-via-alb-opt-in-per-component)
(`sok_web_external_*`, `sok_hec_external_enabled`). DNS records are created as
native `aws_route53_record` resources fed by the Ingress load-balancer hostname
(a `kubernetes_manifest` with a `wait { fields }` block on
`status.loadBalancer.ingress[0].hostname`).
