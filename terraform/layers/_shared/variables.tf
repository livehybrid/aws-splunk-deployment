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
variable "default_subnet_a_cidr" {}
variable "default_subnet_b_cidr" {}
variable "default_subnet_c_cidr" {}

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
  description = "True for a 3-member Search Head Cluster; false for a standalone SH (dev)."
  type        = bool
  default     = true
}

variable "enable_vpc_endpoints" {
  description = "Provision interface VPC endpoints (KMS, EC2, ELB, SSM, Logs, Events, Monitoring, SNS, SQS, ECR). Each costs ~$21/month across 3 AZs. Off by default: instances reach AWS APIs over the IGW. Turn on for private-subnet hardening. The S3 gateway endpoint is always on (free)."
  type        = bool
  default     = false
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
# SOK (eks + sok layers) — only read when deployment_model = "sok"
###############################################################################

variable "eks_kubernetes_version" {
  description = "EKS control-plane version. Coupled constraints (July 2026): SOK 3.1.0 supports K8s 1.25-1.34; K8s 1.34 requires Splunk >= 10.4 (IRSA token format). 1.34 exits standard EKS support 2026-12-02 — after that the parked control plane bills 6x unless upgraded (needs a newer SOK release)."
  type        = string
  default     = "1.34"
}

variable "eks_public_access_cidrs" {
  description = "CIDRs allowed to reach the public EKS API endpoint. Empty = fall back to trusted_cidrs. CI appends the runner egress IP for the duration of a run."
  type        = list(string)
  default     = []
}

variable "eks_cluster_dns_ip" {
  description = "The kube-dns Service ClusterIP (.10 of the EKS service CIDR). Default matches EKS's default 10.100.0.0/16 service CIDR. node-local-dns binds this so it can transparently intercept pod DNS. Override only if the cluster uses a non-default service CIDR."
  type        = string
  default     = "10.100.0.10"
}

variable "eks_vpc_name_tag" {
  description = "Name tag of the (project=splunk) VPC the EKS nodes join. Dev and prod currently share one AWS account with a single splunk VPC tagged Name=prod, so the dev workspace points here at \"prod\". Empty = fall back to var.environment (a workspace that owns its VPC needs no override). The default-{a,b,c} subnets are then discovered within whichever VPC this resolves to."
  type        = string
  default     = ""
}

variable "eks_node_groups" {
  description = "Managed node groups, keyed by name. Splunk Enterprise images are x86-64 only and Splunk 10 requires AVX — no Graviton. Indexer nodes should be on-demand (no Spot for stateful pods)."
  type = map(object({
    instance_type     = string
    desired           = number
    min               = number
    max               = number
    availability_zone = string
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
  description = "splunk/splunk-operator Helm chart version. CRDs are vendored separately in eks/files/ (removed from the chart in 3.0.0) — bump BOTH together."
  type        = string
  default     = "3.1.0"
}

variable "sok_splunk_image" {
  description = "Splunk Enterprise container image for all CRs (x86-64 only). Digest-pinned (SEC-6/DEP-8): the tag documents the version, the digest is what deploys — a mutated tag can't ride into the nightly rebuild. Captured from the validated 10.4.0 deploy; bump tag+digest together."
  type        = string
  default     = "docker.io/splunk/splunk:10.4.0@sha256:5fef7b0d2c83f6e8b3fe3cda5885e2a01e3a6eb99d8502e6333aaa64e7021f62"
}

# Env-scoped Splunk secrets (SEC-1). Defaults are the estate's LEGACY shared
# paths (what prod/EC2 uses today); dev overrides to /dev/splunk/* so dev pods
# never hold prod credentials. Rotation rides the nightly rebuild — the cluster
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
  description = "Set to \"--accept-sgt-current-at-splunk-com\" to accept the Splunk General Terms (https://www.splunk.com/en_us/legal/splunk-general-terms.html). MANDATORY for Splunk 10.x containers under operator >= 3.0.0 — pods refuse to start without it. Deliberately has no accepting default."
  type        = string
  default     = ""
}

variable "sok_indexer_replicas" {
  description = "IndexerCluster peers (single-site shape). The operator floors this at replication_factor and docs state a minimum of 3."
  type        = number
  default     = 3
}

variable "sok_etc_storage" {
  description = "Per-pod /opt/splunk/etc PVC size. The operator NEVER resizes PVCs — size generously."
  type        = string
  default     = "10Gi"
}

variable "sok_var_storage" {
  description = "Per-pod /opt/splunk/var PVC size (holds the SmartStore cache). The operator NEVER resizes PVCs — size generously."
  type        = string
  default     = "50Gi"
}

variable "sok_etc_storage_by_role" {
  description = "Per-role override of sok_etc_storage (NFR-6). Keys: cm, idxc, sh, shc, lm, mc; unset roles use the global. Empty (default) = uniform sizing."
  type        = map(string)
  default     = {}
}

variable "sok_var_storage_by_role" {
  description = "Per-role override of sok_var_storage (NFR-6) — only indexers need the big SmartStore-cache volume; LM/MC/CM idle at a fraction. Keys: cm, idxc, sh, shc, lm, mc; unset roles use the global."
  type        = map(string)
  default     = {}
}

###############################################################################
# SOK external web access (opt-in) — put an internet-facing ALB Ingress in
# front of the Standalone search head's Splunk Web (:8000) so the UI has a real
# HTTPS URL instead of `kubectl port-forward`. OFF by default. See
# terraform/layers/sok/web-ingress.tf and the docs "External access" section.
###############################################################################
variable "eks_console_admin_principal_arns" {
  description = "IAM principal ARNs granted AmazonEKSClusterAdminPolicy via EKS access entries so the AWS Console can browse Kubernetes objects (authentication_mode=API trusts NOBODY by default — not even root). Terraform-managed, so the grant survives the nightly rebuild."
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
  description = "CPUCreditBalance below which the NFR-2 burstable-node alarm fires (min across an ASG's instances). 100 credits is ~2.7h of t3.large baseline runway (36 credits/hr) — enough warning before throttling, high enough to ignore normal burst dips. Tune per node size."
  type        = number
  default     = 100
}

variable "sok_alarm_notify_email" {
  description = "Optional email subscribed to the SOK CloudWatch alarm SNS topic (NFR-2 CPU-credit alarm). Empty = topic created with no email subscription (subscribe a Lambda/AWS Chatbot to reach Slack, or add an address here). AWS emails a confirmation link that must be clicked once."
  type        = string
  default     = ""
}

variable "sok_pod_resources" {
  description = "Per-pod CPU/memory requests+limits for the Splunk CRs. null = the dev Burstable default (requests << limits, everything on one node). Prod sets requests==limits for Guaranteed QoS (NFR-1) — e.g. { requests = { cpu = \"2\", memory = \"8Gi\" }, limits = { cpu = \"2\", memory = \"8Gi\" } }."
  type = object({
    requests = object({ cpu = string, memory = string })
    limits   = object({ cpu = string, memory = string })
  })
  default = null
}

variable "sok_web_external_enabled" {
  description = "Expose Splunk Web (the SOK Standalone search head) on an internet-facing ALB Ingress. OFF by default — the normal access path is `kubectl port-forward`. When true, also set sok_web_external_hostname + sok_web_external_zone_name."
  type        = bool
  default     = false
}

variable "sok_web_external_hostname" {
  description = "FQDN for the external Splunk Web ALB, e.g. sok-dev.splunk.livehybrid.com. MUST be covered by the ACM cert (a *.<zone> wildcard covers exactly one label). A CNAME to the ALB is created in sok_web_external_zone_name."
  type        = string
  default     = ""
}

variable "sok_web_external_zone_name" {
  description = "Route53 public hosted zone that owns sok_web_external_hostname (no trailing dot), e.g. splunk.livehybrid.com. Used for the CNAME record and — if sok_web_external_certificate_arn is empty — to discover the *.<zone> ACM cert."
  type        = string
  default     = ""
}

variable "sok_web_external_certificate_arn" {
  description = "ACM cert ARN for the ALB HTTPS listener. Empty = discover the most-recent ISSUED *.<sok_web_external_zone_name> cert."
  type        = string
  default     = ""
}

variable "sok_web_external_components" {
  description = "Which Splunk UIs the external ALB fronts (host-based routing on ONE ALB). Keys: sh (search tier — Standalone or SHC by shape), cm, lm, mc, deployer (SHC shapes only). Indexers are never exposable (splunkweb disabled on peers). sh uses sok_web_external_hostname; every other component gets <first-label>-<component>.<zone>, still covered by the *.<zone> cert."
  type        = list(string)
  default     = ["sh"]
}

variable "sok_hec_external_enabled" {
  description = "Expose HEC (indexer :8088, HTTPS) on the shared external ALB at <first-label>-hec.<zone>. REQUIRES sok_web_external_enabled=true (the ALB, cert and DNS plumbing are shared). ALB-fronting HEC is supported guidance (sticky sessions are set for useACK senders; Firehose supports ALB since 2024-01 and needs exactly the CA-signed cert the ALB provides; NLB is NOT supported for Firehose). Senders must be within sok_web_external_allowed_cidrs."
  type        = bool
  default     = false
}

variable "sok_web_external_allowed_cidrs" {
  description = "Inbound allow-list on the external Splunk Web ALB. Empty = fall back to trusted_cidrs. Set [\"0.0.0.0/0\"] to make it fully public — NB the SOK admin password is the estate's shared /monitoring/splunk/password (finding SEC-1), so keep this as narrow as the audience allows."
  type        = list(string)
  default     = []
}
