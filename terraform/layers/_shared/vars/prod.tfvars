###############################################################################
# LiveHybrid Splunk C3 — production workspace.
###############################################################################

environment  = "prod"
profile      = "default"
state_bucket = "livehybrid-splunk-prod-terraform"

# DNS — terraform creates the splunk.livehybrid.com Route53 zone; delegate
# the subdomain at your registrar by adding NS records pointing at the new
# zone's nameservers (output by `terraform output dns` after account apply).
create_dns             = true
dns_base_splunk_domain = "splunk.livehybrid.com"

# VPC — single /24 split across 3 AZs.
default_vpc_cidr      = "192.168.10.0/24"
default_subnet_a_cidr = "192.168.10.0/26"
default_subnet_b_cidr = "192.168.10.64/26"
default_subnet_c_cidr = "192.168.10.128/26"

# Splunk AMI — paste the ID from `make packer-build-splunk env=prod`.
# Version + build come from https://raw.githubusercontent.com/livehybrid/downloadSplunk/refs/heads/main/version.list


# C3 roles.
enable_shc = true

# Topology — multisite indexer cluster: 2 indexers per AZ across 2 AZs
# (site1 = eu-west-2a, site2 = eu-west-2b). SHC stays 3 members across
# 3 AZs (SHs are site0 = no search affinity). replication_factor /
# search_factor still govern legacy non-site buckets bootstrapped from
# SmartStore that predate multisite.
replication_factor = 3
search_factor      = 2

multisite       = true
available_sites = "site1,site2"
# Each bucket: 2 copies in its origin site + 1 in the other site, so a
# whole-site (AZ) loss leaves at least one copy of everything.
site_replication_factor_origin = 2
site_replication_factor_total  = 3
site_search_factor_origin      = 1
site_search_factor_total       = 2

# Indexer cache / HF checkpoint volume filesystem ("xfs" or "ext4").
# Applies at volume creation only — changing it does not reformat
# existing volumes.
data_volume_filesystem = "xfs"

# Cost-minimum mode for early dev work — flip use_spot=false and bump
# instance/volume sizes when ready for real workload (typical prod:
# indexer m6i.2xlarge, SH m6i.xlarge, manager/deployer/license/MC m6i.large,
# HF c6i.xlarge, indexer_cache_volume_size = 700).
# Currently 500 GB (matches in-use volumes). To shrink, recycle the indexers
# first (`make recycle env=prod role=indexer`) then lower this and re-apply —
# EBS can't shrink in-place.




# Apps + ops.

# Admin/UI access locked down to your CIDR.
trusted_cidrs = [
  "82.30.10.70/32",
]

# HEC ingestion — open to your CIDR for now; tighten when you wire real producers.

# The dev SOK pods share this (prod) VPC and reach S3 through its gateway
# endpoint, whose policy allowlists specific buckets. Add the dev buckets that
# need *writes* (PutObject) through the endpoint so they aren't 403'd:
#   - SmartStore: indexers roll buckets to it.
#   - kvbackup:   the KV-store backup CronJob uploads SHC KV dumps to it.
# Endpoint-policy only (combined_s3_bucket_access feeds vpc_default_ep.tf, no IAM
# role). The dev apps bucket needs nothing here — the operator only reads it
# (GetObject is already allowed on * by the endpoint's second statement).

# SmartStore S3/KMS path proven end-to-end on a cold boot (uploads
# SSE-KMS-encrypted with the right key, OS trust anchor verifying AWS TLS), and
# cluster-internal TLS verification was already green on 06-10's test boot.
# Bootstrap fails closed if the cert-issuer Lambda is unreachable while this
# flag is true.

###############################################################################
# SOK (eks + sok layers) prod profile — STAGED for the EC2 -> SOK migration.
#
# deployment_model stays "ec2" until the gated cutover: flipping it here would
# gate off the LIVE EC2 Splunk core on the next cluster-layer apply. These knobs
# are inert while ec2, and the exclusivity guard blocks any prod SOK apply while
# EC2 core instances run. The multisite settings above (multisite=true,
# available_sites, site_* factors) are reused by the sok layer as-is, so prod
# SOK is multisite (2 IndexerCluster CRs site1/site2 + a 3-member SHC).
#
# ⚠ Sizing is SMALL to start — right-size before real prod load: indexer pods
#   are packed (shared t3.xlarge), and the operator never resizes PVCs so
#   sok_var_storage is set generously up front. Spike S0b must confirm the
#   operator accepts 2 indexers/site at origin:2 before this is applied.
###############################################################################
sok_accept_splunk_general_terms = "--accept-sgt-current-at-splunk-com"
sok_indexer_replicas            = 2 # PER SITE (2 sites => 4 indexers)
sok_etc_storage                 = "20Gi"
sok_var_storage                 = "200Gi" # SmartStore cache — no operator resize

# Persistent HEC token (OPS-14): foundation creates/seeds /prod/splunk/hec_token
# (out of the nightly teardown); the sok layer reads it so the token is stable
# across rebuilds instead of regenerating each night. Set explicitly to match
# dev even though it equals the variable default.
sok_secret_hec_token_id = "/prod/splunk/hec_token"

# The account layer already owns the live prod SmartStore bucket + KMS key —
# foundation must NOT try to create them (name collision). It creates only the
# apps + kvbackup buckets, SSE-KMS'd with the existing key (found by alias).

# AWS Console "Resources" view on the prod SOK cluster (authentication_mode=API
# trusts nobody implicitly). Same grant as dev; prefer an IAM role long-term.
# NB: on CI-built clusters the CREATOR admin is the CI role — the operator user
# (car) needs an explicit entry here or local kubectl/make targets get 401
# (first prod build-out finding; dev masked it because car built dev locally).
eks_console_admin_principal_arns = [
  "arn:aws:iam::123456789012:root",
  "arn:aws:iam::123456789012:user/car",
]

# Per-AZ node groups: site1 indexers + CM/LM/MC/operator in 2a, site2 in 2b.
# SHC members (site0, no zone affinity) bin-pack across these — add a general-c
# (eu-west-2c) group for full SHC AZ-spread when right-sizing.
# Build-out-test sizing (no workload): 4x t3.large + trimmed pod requests below
# (~$0.37/hr nodes, ~33% under the 3x t3.xlarge shape) at dev-proven pod density
# (~2.3Gi real per pod). t3.medium does NOT pay: the 2Gi-class Splunk footprint
# means 1-2 pods per 4GiB node -> 7+ nodes, no cost win, and real IP pressure on
# the shared /26 subnets. Revert to bigger nodes + default requests for load.
eks_node_groups = {
  general-a = { instance_type = "t3.large", desired = 2, min = 2, max = 3, availability_zone = "eu-west-2a" }
  general-b = { instance_type = "t3.large", desired = 2, min = 2, max = 3, availability_zone = "eu-west-2b" }
}

# Pack pods for the workload-free build-out: requests halved (1Gi floor is fine
# idle; splunk-ansible bring-up bursts ride the 4Gi limit), still Burstable.
# Real prod load => remove this (2Gi default) or go Guaranteed (requests==limits).
sok_pod_resources = {
  requests = { cpu = "200m", memory = "1Gi" }
  limits   = { cpu = "2", memory = "4Gi" }
}

# CI (GitHub Actions) needs an EKS access entry to manage the sok layer —
# creator-admin only covers whoever CREATED the cluster (CI-built clusters
# have it implicitly; locally-built ones do not, which broke the first
# CI-driven dev destroy with k8s Unauthorized).
gh_actions_role_arn = "arn:aws:iam::123456789012:role/GitHubActionsTerraform"
