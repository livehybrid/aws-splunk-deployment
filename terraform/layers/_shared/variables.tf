###############################################################################
# Shared variables for the LiveHybrid Splunk C3 deployment.
#
# Networking / env basics
###############################################################################

variable "region" {
  default = "eu-west-2"
}

variable "environment" {
  description = "Workspace name: prod, dev, etc."
}

variable "profile" {
  description = "Local AWS CLI profile to assume when applying."
}

variable "state_bucket" {
  description = "S3 bucket holding the terraform state for this workspace."
}

variable "default_vpc_cidr" {}

variable "vpc_subnets" {
  type        = map(string)
  description = "Map of AZ suffix to subnet CIDR. Each entry creates one subnet and one route-table association. Keys are single letters (a, b, c …) appended to var.region to form the full AZ name."
}

variable "trusted_cidrs" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}

variable "vpc_flow_log_s3_arn" {
  description = "Optional pre-existing S3 bucket ARN for VPC flow logs. Leave empty to skip flow-log export."
  default     = ""
}

variable "create_dns" {
  default = false
}

variable "use_ecr_pullthrough_cache" {
  type        = bool
  description = <<-EOT
    Route every container image through this account's ECR pull-through cache
    (account/ecr.tf). True (the default) is the estate's posture: nodes with no
    internet path pull the cached copy over the ECR VPC endpoints.

    False sends each image to its upstream registry instead (docker.io,
    registry.k8s.io, public.ecr.aws, ghcr.io), which needs real egress from the
    nodes. Use it in an account that has no pull-through cache configured, and
    note the docker-public rule needs a Docker Hub credential in Secrets
    Manager that a fresh account will not have.
  EOT
  default     = true
}

variable "sok_stoker_index" {
  type        = string
  description = <<-EOT
    Index Stoker's generated events land in. Defaults to stoker_events, defined
    by the sok_loadtest_indexes app in manager-apps.

    Do NOT point this at main. Synthetic load mixed into main contaminates every
    other search, every dashboard and the licence attribution for real data, and
    cleanup stops being "drop the index" and becomes a delete job.
  EOT
  default     = "stoker_events"
}

variable "sok_regulator_index" {
  type        = string
  description = <<-EOT
    Index Regulator's own telemetry lands in (run and worker lifecycle, samples,
    per-search records). Defaults to regulator_telemetry.

    Separate from the Stoker index on purpose: this describes the LOAD
    GENERATOR, not the cluster under test, and keeping them apart is what stops
    someone charting generator latency beside Splunk's own and reading a
    conclusion into the pair.
  EOT
  default     = "regulator_telemetry"
}

variable "sok_internal_hec_url" {
  type        = string
  description = <<-EOT
    HEC endpoint the CONTROL PLANES use for their own telemetry (Stoker's
    DOGFOOD_HEC_URL, Regulator's REG_HEC_URL). Empty (the default) keeps the
    estate's behaviour: the external ALB hostname this layer already derives.

    Point it at the in-cluster Service when the ALB does not admit the
    cluster's own egress address. On an internet-facing ALB with a narrow
    allow-list it never will, and the failure is nasty rather than obvious:
    stoker's transition_run emits dogfood telemetry SYNCHRONOUSLY, so every
    lifecycle transition blocks for a full HEC timeout (~15 s measured, with a
    75 s hang to the ALB from inside the cluster). Submit does two transitions
    and takes 30 s; the worker's ready POST then blows its own 10 s timeout,
    trips the 30 s fence and wedges the engine for the rest of the run.

    This is the same hairpin trap the PUBLIC_BASE_URL comments warn about, with
    the same cause and no warning attached to it.
  EOT
  default     = ""
}

variable "sok_regulator_seed_target_url" {
  type        = string
  description = <<-EOT
    Management URL Regulator seeds its first target with. Empty (the default)
    derives it from the search tier this deployment actually has: the first
    search head CLUSTER if there is one, otherwise the first STANDALONE search
    head. That reproduces the previous hardcoded
    splunk-shc-default-search-head-service on any shape with an SHC named
    "default", and stops pointing at a Service that does not exist on a shape
    without one.
  EOT
  default     = ""
}

variable "s3_endpoint_policy_full_access" {
  type        = bool
  description = <<-EOT
    Let the S3 gateway endpoint reach ANY bucket, instead of the allow-list of
    the SOK buckets plus the ECR starport layer buckets.

    False (the default) keeps the estate's restrictive policy, which is correct
    when every image is pulled through the ECR pull-through cache. It is wrong
    the moment images come from upstream registries: registry.k8s.io serves its
    blobs from a regional S3 bucket, the gateway endpoint intercepts that
    traffic, and the policy denies it. The manifest resolves and the blob fetch
    returns 403, which reads as a broken image rather than a network policy.

    Set true alongside use_ecr_pullthrough_cache = false.
  EOT
  default     = false
}

variable "k8s_proxy_url" {
  type        = string
  description = <<-EOT
    Proxy the kubernetes, helm and kubectl providers dial the EKS API through,
    e.g. "socks5://localhost:1080" for a private cluster endpoint reached over
    a bastion tunnel.

    Empty (the default) dials the endpoint directly, which is right for a public
    (allow-listed) endpoint. Do not set it without a tunnel listening: with a
    proxy configured and nothing there, every Kubernetes resource fails to connect.

    Scripts and the Makefile read the same setting from the K8S_PROXY
    environment variable.
  EOT
  default     = ""
}

variable "extra_default_tags" {
  type        = map(string)
  description = "Additional tags merged into every provider's default_tags, for an organisation tagging policy (cost centre, owner, data classification). The repo's own Project/Service/Environment/Workspace/ManagedBy tags win on a key clash. Note default_tags never reach EC2 instances or EBS volumes launched from a launch template (provider issue #32328); the eks layer forwards them there explicitly."
  default     = {}
}

variable "bucket_prefix" {
  type        = string
  description = <<-EOT
    Prefix for the account-layer S3 buckets and naming convention:
    <bucket_prefix>-<env>-splunk-<purpose> for SmartStore, apps and KV-backup.
    S3 bucket names are globally unique, so override it (e.g. with your org
    short name) to stand this up without colliding with anyone else.
  EOT
  default     = "livehybrid"
}

variable "smartstore_bucket_name_override" {
  type        = string
  description = <<-EOT
    Full name of an EXISTING SmartStore bucket to use instead of the
    <bucket_prefix>-<env>-splunk-smartstore convention, e.g. when adopting a
    bucket that predates this code. Empty (the default) uses the convention.
  EOT
  default     = ""
}

variable "map_public_ip_on_launch" {
  type        = bool
  description = <<-EOT
    Give instances in the default subnets a public IP. True (the default) suits
    an account with no NAT gateway, where nodes need a route to the internet
    to pull images; they are then reachable only through their security groups.
    Set false, together with enable_internet_gateway = false, for private
    subnets whose egress (NAT gateway, transit gateway, proxy) is provided
    outside this repo.
  EOT
  default     = true
}

variable "enable_internet_gateway" {
  type        = bool
  default     = true
  description = "Create an internet gateway and a 0.0.0.0/0 route to it. True (the default) matches map_public_ip_on_launch = true; set both false when egress is provided outside this repo."
}

###############################################################################
# DNS / TLS
###############################################################################

variable "dns_base_splunk_domain" {
  description = "Internal (cluster-mesh) base domain for Splunk roles, e.g. internal.splunk.livehybrid.com."
  default     = "splunk.internal"
}

###############################################################################
# Splunk AMI + version
###############################################################################

###############################################################################
# Feature toggles (C3 roles)
###############################################################################

variable "enable_shc" {
  description = "Deprecated — use sok_standalone_search_heads / sok_search_head_clusters instead. Kept for backwards-compatibility: when both new maps are empty, enable_shc=true produces one SHC named 'default' and enable_shc=false produces one standalone SH named 'default'."
  type        = bool
  default     = true
}

variable "sok_standalone_search_heads" {
  description = <<-EOT
    Map of standalone Search Head CRs to create. Each key becomes the CR name
    suffix (splunk-sh-<key>) and an optional service name in
    sok_web_external_components (sh-<key>). An empty map falls back to
    enable_shc: when enable_shc=false a single standalone SH named "default" is
    created, matching the legacy behaviour.

    Supported per-entry attributes (all optional):
      app_location  - S3 prefix for the sh-apps appSource (default: "sh-<key>-apps/").
                      The legacy single-SH default is "sh-apps/".
  EOT
  type = map(object({
    app_location = optional(string)
  }))
  default = {}
}

variable "sok_search_head_clusters" {
  description = <<-EOT
    Map of Search Head Cluster CRs to create. Each key becomes the CR name
    suffix (splunk-shc-<key>) and exposes service components shc-<key> and
    shc-<key>-deployer in sok_web_external_components. An empty map falls back
    to enable_shc: when enable_shc=true a single SHC named "default" is
    created, matching the legacy behaviour.

    Supported per-entry attributes (all optional):
      app_location  - S3 prefix for the shc-apps appSource (default: "shc-<key>-apps/").
                      The legacy single-SHC default is "shc-apps/".
      replicas      - Number of SHC members (default: 3).
  EOT
  type = map(object({
    app_location = optional(string)
    replicas     = optional(number)
  }))
  default = {}
}

variable "enable_vpc_endpoints" {
  description = "Main switch: provision interface VPC endpoints. When false no interface endpoints are created regardless of vpc_endpoint_services. The S3 gateway endpoint is always on (free)."
  type        = bool
  default     = false
}

variable "vpc_endpoint_services" {
  description = "Which interface VPC endpoints to create when enable_vpc_endpoints=true. Defaults to all available. Remove entries to skip specific endpoints (e.g. dev omits ecr, logs, sqs, sns, monitoring, elb, events to reduce cost)."
  type        = set(string)
  default     = ["kms", "ec2", "elb", "ssm", "logs", "events", "monitoring", "sns", "sqs", "ecr"]
}

###############################################################################
# Sizing
###############################################################################

variable "replication_factor" {
  default = 3
}

variable "search_factor" {
  default = 2
}

# Multisite indexer clustering (sites map to AZs: a=site1, b=site2, c=site3).
# When false, the site_* factors are ignored and the cluster is single-site.
variable "multisite" {
  default = false
}

variable "sok_allow_multisite_standalone_sh" {
  description = <<-EOT
    Opt past terraform_data.search_tier_guard, which normally FAILS the plan when
    multisite = true and sok_standalone_search_heads is non-empty.

    splunk-ansible has no supported route to a multisite standalone search head
    (splunk_standalone ships no setup_multisite.yml, and peer_cluster_master.yml
    rewrites [clustering] with multisite = false on every pod start), so the
    default of false is the safe position: fail loudly rather than build a search
    head that silently searches one site.

    Set true to turn on the SPLUNK_ANSIBLE_POST_TASKS route: the Standalone CR
    gets a small playbook (ConfigMap splunk-sh-multisite-post, sok/configmaps.tf)
    that runs splunk_search_head's own setup_multisite.yml AFTER site.yml has
    completed, which is the only point in the container lifecycle that
    peer_cluster_master.yml does not rewrite afterwards. It supplies splunk.site
    and splunk.multisite_master there rather than in spec.defaults, so normal
    peering still happens first and multisite is layered on top.

    Only has an effect when multisite = true AND sok_standalone_search_heads is
    non-empty (local.sh_multisite_enabled in sok/crs.tf gates the machinery on
    all three, so setting this on a single-site cluster does nothing).

    ⚠ NOT YET VERIFIED on a live pod. Confirm with `splunk list cluster-config`
    on the SH; if multisite still reads false, use a 1-member SearchHeadCluster.
  EOT
  type        = bool
  default     = false
}

variable "sok_splunk_image_by_role" {
  description = <<-EOT
    Per-role override of var.sok_splunk_image, so a Splunk upgrade can be staged
    one role at a time (bump, apply, confirm, move on) instead of rotating every
    CR off one variable.

    Keys, most specific first:
      lm | mc | cm                    the management tier
      idxc                            all indexers (both single-site and every site)
      idxc-site1 | idxc-site2         one multisite site only, overrides idxc
      sh | shc                        all standalone SHs / all SHCs
      sh-<key> | shc-<key>            one named instance, overrides sh / shc

    Empty (the default) gives every CR var.sok_splunk_image, exactly as before.

    The operator DOES sequence a multi-CR image change on its own
    (docs/SplunkOperatorUpgrade.md), but that order upgrades Standalone SECOND,
    ahead of the LM and CM, and the doc frames it around an operator release
    rather than a Terraform spec.image change. Staging by hand is deterministic
    and depends on neither.
  EOT
  type        = map(string)
  default     = {}
}

###############################################################################
# Stoker (github.com/livehybrid/stoker) — HEC data-generator control plane.
###############################################################################

variable "sok_enable_stoker" {
  description = <<-EOT
    Deploy the Stoker control plane into the splunk namespace, for generating
    test data into this cluster's own HEC. OFF by default; nothing is created
    when false.

    Expose its UI by adding "stoker" to sok_web_external_components (it is
    routed on port 8080, not 8000, see local.web_component_ports).

    ⚠ ONE MANUAL STEP per build. Launching workers on Kubernetes needs a row in
    the `fleets` table with driver = "k8s" and config_json
    {"namespace": "<namespace>"}. seed_fleets() only ever creates fake-local and
    swarm-local, and there is no /api/fleets endpoint, so it cannot be created
    through the API. Add it once after the stack is up (see stoker.tf).
  EOT
  type        = bool
  default     = false
}

variable "sok_stoker_image" {
  description = "Stoker control-plane image. Multi-arch and cosign-signed upstream."
  type        = string
  default     = "ghcr.io/livehybrid/stoker:latest"
}

variable "sok_stoker_worker_image" {
  description = "Stoker WORKER image, passed as WORKER_IMAGE. The control plane launches this as Indexed Jobs; it is never run by this layer directly."
  type        = string
  default     = "ghcr.io/livehybrid/stoker-worker:latest"
}

variable "sok_stoker_database_url" {
  description = <<-EOT
    DATABASE_URL for the control plane. Defaults to SQLite on the pod's own PVC,
    which is stoker's own default (server/config.py DEFAULT_DATABASE_URL) and is
    the right shape for a nightly-rebuilt dev estate: one pod, one file, no
    second workload.

    Point it at a postgresql+psycopg:// URL to use Postgres instead (the shape
    the upstream swarm stack runs). This layer does NOT create a Postgres for
    you; that is a deliberate scope line.
  EOT
  type        = string
  default     = "sqlite:////data/stoker.db"
}

variable "sok_stoker_public_base_url" {
  description = <<-EOT
    Override PUBLIC_BASE_URL. Empty (default) uses the in-cluster Service URL
    http://stoker:8080.

    ⚠ This is the URL WORKERS use to reach the control plane, not just a display
    string: docs/WORKER-CONTRACT.md projects STOKER_CONTROL_URL = PUBLIC_BASE_URL
    into every worker pod. Setting it to the external ALB hostname makes workers
    hairpin out through NAT to a load balancer whose allow-list does not include
    the cluster's egress IP, and runs hang in provisioning. Only set this if that
    path genuinely works.
  EOT
  type        = string
  default     = ""
}

variable "sok_stoker_storage" {
  description = "Size of the Stoker PVC holding /data (SQLite file, bundle tarballs, git clones)."
  type        = string
  default     = "5Gi"
}

variable "available_sites" {
  default = "site1,site2"
}

variable "site_replication_factor_origin" {
  default = 2
}

variable "site_replication_factor_total" {
  default = 3
}

variable "site_search_factor_origin" {
  default = 1
}

variable "site_search_factor_total" {
  default = 2
}

# Filesystem for indexer cache / HF checkpoint volumes ("xfs" or "ext4").
variable "data_volume_filesystem" {
  default = "xfs"
}

###############################################################################
# Scale (per-AZ)
#
# For dev workspaces, set b and c to 0 to collapse to single-AZ.
###############################################################################

###############################################################################
# Alerting
###############################################################################

###############################################################################
# Ingestion / git
###############################################################################

###############################################################################
# Module-internal
###############################################################################

###############################################################################
# Deployment model (EC2 vs Splunk Operator for Kubernetes)
###############################################################################

###############################################################################
# SOK (eks + sok layers), only read when deployment_model = "sok"
###############################################################################

variable "eks_enable_public_access" {
  description = "Enable EKS access from public IP"
  type        = bool
  default     = false
}

variable "eks_enable_private_access" {
  description = "Enable EKS access from VPC IP"
  type        = bool
  default     = true
}

variable "eks_kubernetes_version" {
  description = "EKS control-plane version. Coupled constraints (July 2026): SOK 3.1.0 supports K8s 1.25-1.34; K8s 1.34 requires Splunk >= 10.4 (IRSA token format). 1.34 exits standard EKS support 2026-12-02, after that the parked control plane bills 6x unless upgraded (needs a newer SOK release)."
  type        = string
  default     = "1.34"
}

variable "eks_public_access_cidrs" {
  description = "CIDRs allowed to reach the public EKS API endpoint. Empty = fall back to trusted_cidrs. CI appends the runner egress IP for the duration of a run."
  type        = list(string)
  default     = []
}

variable "eks_vpc_name_tag" {
  description = "Name tag of the VPC the EKS nodes join. Empty (the default) uses this workspace's own VPC, splunk-sok-<environment>. Set it to share another environment's VPC, for example running dev inside the prod VPC in a single account; the default-{a,b,c} subnets are then discovered within that VPC."
  type        = string
  default     = ""
}

variable "eks_node_groups" {
  description = "Managed node groups, keyed by name. Splunk Enterprise images are x86-64 only and Splunk 10 requires AVX, no Graviton. Indexer nodes should be on-demand (no Spot for stateful pods). Set role to pin a group to a Splunk role via a label + NoSchedule taint (e.g. \"indexer\"); empty = general pool. Set nvme_local_storage = true on instance families with NVMe instance-store (e.g. i7i) to assemble drives into a RAID-0 at /mnt/k8s-disks on boot. Set gpu = true on a GPU instance family (g5, g6e, p5) for the AI tier; leave role empty on GPU groups, the GPU taint already reserves them."
  type = map(object({
    instance_type = string
    # Optional fallback pool. A spot request pinned to ONE instance type is
    # pinned to one capacity pool, and when that pool is empty the group simply
    # never launches (UnfulfillableCapacity, node group ACTIVE with no nodes).
    # Listing several comparable types lets the ASG place the node somewhere.
    # Empty (the default) keeps the single instance_type above.
    #
    # x86-64 only, and Splunk 10 needs AVX, so no Graviton. Note for anything
    # you intend to MEASURE: a heterogeneous pool means successive runs can
    # land on different silicon, so record the type a benchmark actually ran on
    # or keep that group pinned to one type.
    instance_types     = optional(list(string), [])
    desired            = number
    min                = number
    max                = number
    availability_zone  = string
    role               = optional(string, "")
    nvme_local_storage = optional(bool, false)
    labels             = optional(map(string), {})
    # ON_DEMAND (default) or SPOT. Spot is roughly 60-70% cheaper and fine for
    # stateless, restartable work. It is NOT fine for a stateful pod: a
    # reclaimed node takes its hot buckets with it, and at RF=1/SF=1 there is
    # no replica to recover from. Changing this REPLACES the node group.
    capacity_type = optional(string, "ON_DEMAND")
    # GPU group for the AI tier: NVIDIA AMI (driver + container toolkit), a
    # nvidia.com/gpu.present label and a nvidia.com/gpu:NoSchedule taint so only
    # GPU workloads land there. See terraform/layers/ai.
    gpu = optional(bool, false)
  }))
  default = {
    general-a = {
      instance_type     = "t3.xlarge"
      desired           = 2
      min               = 2
      max               = 3
      availability_zone = "eu-west-2a"
    }
  }
}

variable "gh_actions_role_arn" {
  description = "IAM role ARN used by GitHub Actions terraform workflows (repo variable AWS_TERRAFORM_ROLE_ARN); granted an EKS admin access entry so CI can manage the sok layer. Empty = skip."
  type        = string
  default     = ""
}

variable "sok_namespace" {
  description = "Namespace for the Splunk Operator AND all Splunk CRs. Must be one namespace: a namespace-scoped operator only watches its own namespace (WATCH_NAMESPACE)."
  type        = string
  default     = "splunk"
}

variable "sok_operator_chart_version" {
  description = "splunk/splunk-operator Helm chart version. CRDs are vendored separately in sok/files/ (removed from the chart in 3.0.0), bump BOTH together. 3.2.0 (2026-09-24) supports K8s 1.32-1.36 and Splunk 9.4.15-10.6.0, and is the release that unblocks the 1.35/1.36 upgrade this estate needs before 1.34 leaves standard EKS support on 2026-12-02. It also adds spec.certs[] (see certs.tf), which sok_private_ca_enabled requires."
  type        = string
  default     = "3.2.0"
}

variable "sok_splunk_image" {
  description = "Splunk Enterprise container image for all CRs (x86-64 only). Digest-pinned (SEC-6/DEP-8): the tag documents the version, the digest is what deploys, a mutated tag can't ride into the nightly rebuild. Captured from the validated 10.4.0 deploy; bump tag+digest together."
  type        = string
  default     = "docker.io/splunk/splunk:10.4.1"
}

# Env-scoped Splunk secrets (SEC-1). Defaults are the estate's LEGACY shared
# paths (what prod/EC2 uses today); dev overrides to /dev/splunk/* so dev pods
# never hold prod credentials. Rotation rides the nightly rebuild, the cluster
# re-forms with whatever these point at.
variable "sok_secret_admin_password_id" {
  description = "Secrets Manager id of the Splunk admin password for the SOK global secret. dev: /dev/splunk/password (env-scoped, SEC-1)."
  type        = string
  default     = "/monitoring/splunk/password"
}

variable "sok_secret_pass4symmkey_id" {
  description = "Secrets Manager id of the cluster/SHC symmetric key. dev: /dev/splunk/pass4SymmKey (env-scoped, SEC-1)."
  type        = string
  default     = "/splunk/pass4SymmKey"
}

variable "sok_secret_license_id" {
  description = "Secrets Manager id of the enterprise licence blob. dev: /dev/splunk/license."
  type        = string
  default     = "/monitoring/splunk/license"
}

variable "sok_secret_hec_token_id" {
  description = "Secrets Manager id of the persistent HEC token (OPS-14). CREATED and seeded by the account layer (which is not part of the nightly teardown), then read here so the token survives every rebuild instead of regenerating. Matches the /<env>/splunk/hec_token naming convention the account layer writes."
  type        = string
  default     = "/prod/splunk/hec_token"
}

variable "sok_accept_splunk_general_terms" {
  description = "Set to \"--accept-sgt-current-at-splunk-com\" to accept the Splunk General Terms (https://www.splunk.com/en_us/legal/splunk-general-terms.html). MANDATORY for Splunk 10.x containers under operator >= 3.0.0, pods refuse to start without it. Deliberately has no accepting default."
  type        = string
  default     = ""
}

variable "sok_indexer_replicas" {
  description = "IndexerCluster peers (single-site shape). The operator floors this at replication_factor and docs state a minimum of 3."
  type        = number
  default     = 3
}

variable "sok_etc_storage" {
  description = "Per-pod /opt/splunk/etc PVC size. The operator NEVER resizes PVCs, size generously."
  type        = string
  default     = "10Gi"
}

variable "sok_var_storage" {
  description = "Per-pod /opt/splunk/var PVC size (holds the SmartStore cache). The operator NEVER resizes PVCs, size generously."
  type        = string
  default     = "50Gi"
}

variable "sok_etc_storage_by_role" {
  description = "Per-role override of sok_etc_storage (NFR-6). Keys: cm, idxc, sh, shc, lm, mc; unset roles use the global. Empty (default) = uniform sizing."
  type        = map(string)
  default     = {}
}

variable "sok_var_storage_by_role" {
  description = "Per-role override of sok_var_storage (NFR-6), only indexers need the big SmartStore-cache volume; LM/MC/CM idle at a fraction. Keys: cm, idxc, sh, shc, lm, mc; unset roles use the global."
  type        = map(string)
  default     = {}
}

###############################################################################
# SOK external web access (opt-in), put an internet-facing ALB Ingress in
# front of the Standalone search head's Splunk Web (:8000) so the UI has a real
# HTTPS URL instead of `kubectl port-forward`. OFF by default. See
# terraform/layers/sok/web-ingress.tf and the docs "External access" section.
###############################################################################
variable "eks_console_admin_principal_arns" {
  description = "IAM principal ARNs granted AmazonEKSClusterAdminPolicy via EKS access entries so the AWS Console can browse Kubernetes objects (authentication_mode=API trusts NOBODY by default, not even root). Terraform-managed, so the grant survives the nightly rebuild."
  type        = list(string)
  default     = []
}

variable "sok_network_policies_enabled" {
  description = "Enforce the splunk-namespace egress NetworkPolicy (SEC-5: no path from SOK pods to VPC-internal Splunk ports). Needs the vpc-cni network-policy agent (eks layer). Escape hatch: false."
  type        = bool
  default     = true
}

variable "sok_alert_webhook_secret_id" {
  description = "Secrets Manager id holding a Slack webhook URL for the in-cluster alert watchdog (OPS-4 option a). Empty = watchdog not deployed. Store it with: aws secretsmanager create-secret --name /monitoring/slack/webhook --secret-string '<url>'."
  type        = string
  default     = ""
}

variable "sok_cpucredit_low_threshold" {
  description = "CPUCreditBalance below which the NFR-2 burstable-node alarm fires (min across an ASG's instances). 100 credits is ~2.7h of t3.large baseline runway (36 credits/hr), enough warning before throttling, high enough to ignore normal burst dips. Tune per node size."
  type        = number
  default     = 100
}

variable "sok_alarm_notify_email" {
  description = "Optional email subscribed to the SOK CloudWatch alarm SNS topic (NFR-2 CPU-credit alarm). Empty = topic created with no email subscription (subscribe a Lambda/AWS Chatbot to reach Slack, or add an address here). AWS emails a confirmation link that must be clicked once."
  type        = string
  default     = ""
}

variable "sok_pod_resources" {
  description = "Per-pod CPU/memory requests+limits for the Splunk CRs. null = the dev Burstable default (requests << limits, everything on one node). Prod sets requests==limits for Guaranteed QoS (NFR-1), e.g. { requests = { cpu = \"2\", memory = \"8Gi\" }, limits = { cpu = \"2\", memory = \"8Gi\" } }."
  type = object({
    requests = object({ cpu = string, memory = string })
    limits   = object({ cpu = string, memory = string })
  })
  default = null
}

variable "sok_web_external_enabled" {
  description = "Expose Splunk Web (the SOK Standalone search head) on an internet-facing ALB Ingress. OFF by default, the normal access path is `kubectl port-forward`. When true, also set sok_web_external_hostname + sok_web_external_zone_name."
  type        = bool
  default     = false
}

variable "sok_alb_is_internet_facing" {
  description = "If the SOK ALB scheme should be internet facing or internal to the VPC"
  type        = bool
  default     = false
}

variable "sok_web_external_hostname" {
  description = "FQDN for the external Splunk Web ALB, e.g. sok-dev.splunk.livehybrid.com. MUST be covered by the ACM cert (a *.<zone> wildcard covers exactly one label). A CNAME to the ALB is created in sok_web_external_zone_name."
  type        = string
  default     = ""
}

variable "sok_web_external_zone_name" {
  description = "Route53 public hosted zone that owns sok_web_external_hostname (no trailing dot), e.g. splunk.livehybrid.com. Used for the CNAME record and, if sok_web_external_certificate_arn is empty, to discover the *.<zone> ACM cert."
  type        = string
  default     = ""
}

variable "sok_web_external_certificate_arn" {
  description = "ACM cert ARN for the ALB HTTPS listener. Empty = discover the most-recent ISSUED *.<sok_web_external_zone_name> cert. Set this to the account layer's sok_web_certificate_arn output when issuing from an organisation private CA (see acm_private_ca_arn)."
  type        = string
  default     = ""
}

variable "acm_private_ca_arn" {
  description = <<-EOT
    ARN of an organisation AWS Private CA (ACM PCA) to issue the SOK web ALB
    certificate from, e.g. arn:aws:acm-pca:eu-west-2:<acct>:certificate-authority/<id>.

    Empty (default) creates nothing and nothing changes: the sok layer keeps
    using sok_web_external_certificate_arn, or discovers the most-recent ISSUED
    public *.<sok_web_external_zone_name> certificate.

    When set, the ACCOUNT layer issues a *.<sok_web_external_zone_name>
    certificate (with the apex as a SAN) from that CA and exports it as
    sok_web_certificate_arn. It lives in the account layer because that layer is
    persistent; the sok layer is destroyed nightly and a certificate that came
    and went with it would churn the CA's issuance record for no reason.

    Requires sok_web_external_zone_name to be set. Clients must trust the org
    root, so this suits an internal ALB (sok_alb_is_internet_facing = false).
  EOT
  type        = string
  default     = ""
}

variable "sok_web_external_components" {
  description = "Which Splunk UIs the external ALB fronts (host-based routing on ONE ALB). Keys: sh-<key> per entry in sok_standalone_search_heads, shc-<key> and shc-<key>-deployer per entry in sok_search_head_clusters, plus cm, lm, mc. Indexers are never exposable (splunkweb disabled on peers). One component answers on sok_web_external_hostname (see sok_web_canonical_component); every other one gets <first-label>-<component>.<zone>, still covered by the *.<zone> cert. An unknown key fails the plan."
  type        = list(string)
  default     = ["shc-default"]
}

variable "sok_web_external_component_hostnames" {
  description = "Optional per-component hostname override, keyed by the component key from sok_web_external_components. A bare label (no dot) is placed under sok_web_external_zone_name, e.g. \"search\" -> search.<zone>; a value containing a dot is used verbatim as an FQDN and you must ensure the ACM cert covers it (a *.<zone> wildcard covers exactly one label). Unset components fall back to <first-label-of-sok_web_external_hostname>-<component minus its sh-/shc- prefix>.<zone>. Use this when two components would otherwise derive the same hostname, or just to shorten a URL. Keys must appear in sok_web_external_components."
  type        = map(string)
  default     = {}
}

variable "sok_web_canonical_component" {
  description = "Component from sok_web_external_components that answers on sok_web_external_hostname itself rather than a derived <first-label>-<component>.<zone> name, e.g. \"sh-ops\" or \"shc-default\". Empty = automatic: the sole standalone SH when there is exactly one SH and no SHC (the legacy single-SH shape), otherwise NO component takes the bare hostname and it resolves to nothing. Set this on any multi-SH or SHC shape if you want the plain hostname to work. Must also appear in sok_web_external_components."
  type        = string
  default     = ""
}

variable "sok_hec_external_enabled" {
  description = "Expose HEC (indexer :8088, HTTPS) on the shared external ALB at <first-label>-hec.<zone>. REQUIRES sok_web_external_enabled=true (the ALB, cert and DNS plumbing are shared). ALB-fronting HEC is supported guidance (sticky sessions are set for useACK senders; Firehose supports ALB since 2024-01 and needs exactly the CA-signed cert the ALB provides; NLB is NOT supported for Firehose). Senders must be within sok_web_external_allowed_cidrs."
  type        = bool
  default     = false
}

variable "sok_web_external_allowed_cidrs" {
  description = "Inbound allow-list on the external Splunk Web ALB. Empty = fall back to trusted_cidrs. Set [\"0.0.0.0/0\"] to make it fully public, NB the SOK admin password is the estate's shared /monitoring/splunk/password (finding SEC-1), so keep this as narrow as the audience allows."
  type        = list(string)
  default     = []
}

variable "sok_indexer_nvme_var_storage" {
  description = "When true, indexer var (SmartStore cache) PVCs use the splunk-local-nvme StorageClass backed by instance-store NVMe RAID-0 (/mnt/k8s-disks). Requires nvme_local_storage=true on the indexer node groups and the local-path-provisioner to be deployed. etc PVCs always stay on EBS regardless."
  type        = bool
  default     = false
}

variable "sok_cm_az" {
  description = <<-EOT
    Availability zone to pin the ClusterManager pod and its EBS PVCs to. The CM
    must stay in one AZ because its StorageClass is AZ-scoped (splunk-gp3-xfs-<az>)
    and Kubernetes cannot move an EBS volume across AZs. Defaults to the first AZ
    returned by data.aws_availability_zones (eu-west-2a in eu-west-2). Override
    when the first AZ is unavailable or you want the CM in a specific AZ, e.g.
    "eu-west-2b". For multisite this should always be the site1 AZ so the CM
    co-locates with its EBS volume in the primary site.
  EOT
  type        = string
  default     = null
}

variable "sok_indexer_node_role" {
  description = "Node role label/taint value that indexer pods must tolerate and be attracted to (matches eks_node_groups[*].role). Empty = no dedicated node group, indexers schedule on any general node (current behaviour)."
  type        = string
  default     = ""
}

variable "sok_stoker_node_role" {
  description = "Node role label/taint value that the stoker Deployment must tolerate and be attracted to (matches eks_node_groups[*].role). Empty = stoker schedules on any general node (current behaviour)."
  type        = string
  default     = ""
}

variable "sok_enable_regulator" {
  description = <<-EOT
    Deploy the Regulator control plane into the splunk namespace, for driving
    concurrent Splunk search load and measuring cluster performance. OFF by
    default; nothing is created when false.

    Expose its UI by adding "regulator" to sok_web_external_components (routed
    on port 8080, same as stoker).

    ⚠ NO CPU LIMIT on the control-plane pod by design. A throttled load
    generator produces invalid benchmarks; the memory limit is enforced instead.
  EOT
  type        = bool
  default     = false
}

variable "sok_regulator_image" {
  description = "Regulator control-plane image."
  type        = string
  default     = "ghcr.io/livehybrid/regulator:latest"
}

variable "sok_regulator_worker_image" {
  description = "Regulator API engine worker image, passed as REG_WORKER_IMAGE."
  type        = string
  default     = "ghcr.io/livehybrid/regulator-worker:latest"
}

variable "sok_regulator_browser_worker_image" {
  description = "Regulator browser engine worker image (Chromium/Playwright), passed as REG_BROWSER_WORKER_IMAGE."
  type        = string
  default     = "ghcr.io/livehybrid/regulator-worker:browser"
}

variable "sok_regulator_database_url" {
  description = <<-EOT
    REG_DATABASE_URL for the control plane. Defaults to SQLite on the pod's own
    PVC — the right shape for a nightly-rebuilt dev estate: one pod, one file.
    Regulator's SQLite backend is single-process by design; the Recreate
    deployment strategy enforces this.
  EOT
  type        = string
  default     = "sqlite:////data/regulator.db"
}

variable "sok_regulator_public_base_url" {
  description = <<-EOT
    Override REG_PUBLIC_BASE_URL. Empty (default) uses the in-cluster Service
    URL http://regulator:8080.

    ⚠ Workers use this URL to reach the control plane. Setting it to the
    external ALB hostname makes workers hairpin out through NAT to a load
    balancer whose allow-list does not include the cluster's egress IP, and runs
    hang in provisioning. Only set this if that path genuinely works.
  EOT
  type        = string
  default     = ""
}

variable "sok_regulator_storage" {
  description = "Size of the Regulator PVC holding /data (SQLite database and imported scenario files)."
  type        = string
  default     = "10Gi"
}

variable "sok_stoker_worker_cpu_request" {
  type        = string
  description = "CPU request for Stoker k8s worker pods (e.g. \"1\"). Empty (default) leaves worker Jobs with no resources block, the pre-existing behaviour. See the note in stoker.tf: only read when the k8s-local fleet row is first seeded."
  default     = ""
}

variable "sok_stoker_worker_memory_request" {
  type        = string
  description = "Memory request for Stoker k8s worker pods (e.g. \"1Gi\"). Empty = omit."
  default     = ""
}

variable "sok_stoker_worker_cpu_limit" {
  type        = string
  description = "CPU limit for Stoker k8s worker pods. Usually left empty: a limit caps eventgen throughput, whereas a request reserves a share without capping it."
  default     = ""
}

variable "sok_stoker_worker_memory_limit" {
  type        = string
  description = "Memory limit for Stoker k8s worker pods (e.g. \"2Gi\"). Empty = omit."
  default     = ""
}

variable "sok_regulator_node_role" {
  description = "Node role label/taint value that the Regulator Deployment must tolerate and be attracted to (matches eks_node_groups[*].role). Empty = regulator schedules on any general node."
  type        = string
  default     = ""
}
###############################################################################
# TLS from AWS Private CA. See docs/private-ca-tls.md.
#
# sok_private_ca_enabled defaults to false. With it false, certs.tf creates
# nothing and every Splunk CR renders exactly as without it.
###############################################################################

variable "sok_private_ca_enabled" {
  description = "Master toggle for the ACM PCA TLS stack: cert-manager, aws-privateca-issuer, one leaf certificate per Splunk CR, and spec.certs[] on every CR so the operator wires Splunk's TLS itself. OFF by default: with it false, certs.tf creates no resources and every CR renders exactly as today. Requires acm_private_ca_arn (the organisation CA the account layer already uses) and sok_operator_chart_version >= 3.2.0."
  type        = bool
  default     = false
  nullable    = false
}

variable "sok_private_ca_leaf_duration" {
  description = "Validity of each issued leaf certificate, as a Go duration. Default 168h (7 days) because that is the maximum a SHORT_LIVED_CERTIFICATE-mode CA will issue, so it works against either mode of acm_private_ca_arn without knowing which it is. ⚠ splunkd reads its certificate only at startup, so this value is also the Splunk restart cadence: lengthen it (e.g. 2160h = 90d) against a GENERAL_PURPOSE CA before this goes anywhere long-lived. Rotation is deliberately unsolved for the spike."
  type        = string
  default     = "168h"
  nullable    = false
}

variable "sok_private_ca_renew_before" {
  description = "How long before expiry cert-manager renews, as a Go duration. Must be less than sok_private_ca_leaf_duration. Default 56h = one third of the 7-day default."
  type        = string
  default     = "56h"
  nullable    = false
}

variable "sok_private_ca_s2s_enabled" {
  description = "Also give the indexer CRs a `role: input` cert, which is how SOK 3.2.0 puts TLS on S2S. ⚠ The operator's input role converts the EXISTING 9997 listener rather than adding a second one, so this is a cutover: forwarders must move in step, there is no plaintext-and-TLS side-by-side period. Set false to test pod-to-pod splunkd TLS (8089) only."
  type        = bool
  default     = true
  nullable    = false
}

variable "sok_private_ca_s2s_sans" {
  description = "Extra DNS SANs added to the INDEXER certificates only: the externally dialled S2S name(s), e.g. [\"s2s.example.internal\"]. ⚠ Required when sok_private_ca_s2s_enabled = true. Through the S2S NLB (TCP passthrough) TLS terminates on the pod but the forwarder dialled the NLB/Route53 name, so without it as a SAN every forwarder fails sslVerifyServerCert and ingestion stops."
  type        = list(string)
  default     = []
  nullable    = false
}

variable "sok_cert_manager_chart_version" {
  description = "cert-manager Helm chart version. The operator consumes cert-manager's native Secret shape (tls.crt / tls.key / ca.crt) directly, so no special output format is needed. 3.2.0 of the operator ships against cert-manager v1.21.x."
  type        = string
  default     = "1.21.2"
  nullable    = false
}

variable "sok_privateca_issuer_chart_version" {
  description = "aws-privateca-issuer Helm chart version (the cert-manager external issuer that turns a CertificateRequest into an acm-pca:IssueCertificate call)."
  type        = string
  default     = "1.9.2"
  nullable    = false
}
###############################################################################
# Splunk AI tier. See docs/ai-tier.md and terraform/layers/ai.
#
# ai_tier_enabled defaults to false. With it false the account layer creates no
# artifacts bucket, the sok layer installs nothing extra and the ai layer
# creates nothing.
###############################################################################

variable "ai_tier_enabled" {
  description = "Deploy the Splunk AI tier (Splunk AI Operator + AIPlatform: Ray inference on GPU, Weaviate, the Splunk AI Assistant backend and the SLIM service) onto this cluster, connected to the SOK standalone search head. Needs at least one eks_node_groups entry with gpu = true. Also makes the sok layer install cert-manager, which the AI operator's webhooks require."
  type        = bool
  default     = false
  nullable    = false
}

variable "ai_operator_chart_version" {
  description = "splunk-ai-operator Helm chart version (github.com/splunk/splunk-ai-operator releases). 1.0.0 is the first GA release (2026-08-27)."
  type        = string
  default     = "1.0.0"
  nullable    = false
}

variable "ai_images" {
  description = <<-EOT
    AIPlatform images. The defaults are the combination Splunk qualified for AI
    tier v1.0 (deployment guide, "Supported release combination"), all public on
    Docker Hub. The chart's own image defaults are NOT that combination, which is
    why they are always set explicitly here. Pulled through the ECR pull-through
    cache when use_ecr_pullthrough_cache is on.
  EOT
  type = object({
    saia_api         = optional(string, "docker.io/splunk/ai-tier-saia-api:v1.0")
    saia_api_v2      = optional(string, "docker.io/splunk/ai-tier-saia-api-v2:v1.0")
    saia_data_loader = optional(string, "docker.io/splunk/ai-tier-saia-data-loader:v1.0")
    slim             = optional(string, "docker.io/splunk/ai-tier-slim-service:v1.0")
    ray_head         = optional(string, "docker.io/splunk/ai-tier-ray-head:v1.0")
    ray_worker       = optional(string, "docker.io/splunk/ai-tier-ray-worker:v1.0")
    weaviate         = optional(string, "docker.io/semitechnologies/weaviate:stable-v1.28-007846a")
  })
  default  = {}
  nullable = false
}

variable "ai_features" {
  description = "AIPlatform features to enable. saia = the Splunk AI Assistant backend; slim = the model service the Splunk AI Toolkit calls for `ai` and CDTSM SPL. Both need the matching Splunk app on the search head (see docs/ai-tier.md)."
  type        = list(string)
  default     = ["saia", "slim"]
  nullable    = false
}

variable "ai_accelerator_type" {
  description = "GPU model the inference deployments are built for: \"L40S\" (g6e) or \"H100\" (p5). Selects which model weights are served, so it must match both the GPU node group and the weights staged into the artifacts bucket."
  type        = string
  default     = "L40S"
  nullable    = false
}

variable "ai_gpu_instance_type" {
  description = "Instance type of the GPU node group, passed to the AIPlatform so Ray sizes its worker groups to it. Must match an eks_node_groups entry with gpu = true. Splunk's recommended default is g6e.12xlarge (4x L40S, ~$7.77/h on-demand per Splunk's EKS guide; check your region)."
  type        = string
  default     = "g6e.12xlarge"
  nullable    = false
}

variable "ai_search_head" {
  description = "Key of the sok_standalone_search_heads entry the AI tier connects to (JWT issuer and the Splunk AI Assistant app). AI tier v1.0 is qualified against a standalone search head only; a search head cluster is not a supported target."
  type        = string
  default     = "default"
  nullable    = false
}

variable "ai_vector_db_storage" {
  description = "Persistent volume size for the Weaviate vector database."
  type        = string
  default     = "100Gi"
  nullable    = false
}

variable "ai_ingress_host" {
  description = "Public hostname for SAIA behind the ALB, e.g. \"ai.example.com\". The browser calls SAIA directly (the search head only issues the JWT), so users need a route to it, and it must be HTTPS whenever Splunk Web is, or the browser blocks it as mixed content. Empty = no ingress: SAIA is reachable in-cluster only, enough for the search head's server-side calls but not for users."
  type        = string
  default     = ""
  nullable    = false
}

variable "ai_monitoring_enabled" {
  description = "Install kube-prometheus-stack (Prometheus only; Grafana and Alertmanager stay off) with the AI operator and turn on the AIPlatform Prometheus sidecars. Leave it on unless the cluster ALREADY runs the Prometheus Operator: the AI operator's AIService controller watches ServiceMonitor and will not start without that CRD, so false is only safe where something else provides it."
  type        = bool
  default     = true
  nullable    = false
}

variable "ai_nvidia_device_plugin_chart_version" {
  description = "NVIDIA k8s-device-plugin Helm chart version (nvidia.github.io/k8s-device-plugin). Advertises nvidia.com/gpu on the gpu = true node groups."
  type        = string
  default     = "0.20.1"
  nullable    = false
}

variable "ai_object_storage_secret" {
  description = "Name of a Secret (in the SOK namespace) holding s3_access_key and s3_secret_key for the AI artifacts bucket. Empty (the default) uses IRSA, which is the intended path on EKS. Only set it if Ray workers fail to download weights with an access error, which would mean the downloader does not honour web identity."
  type        = string
  default     = ""
  nullable    = false
}
