###############################################################################
# LiveHybrid Splunk C3 — dev workspace.
#
# Same architecture as prod, single AZ (eu-west-2a only), one instance per role,
# RF=1/SF=1, smaller instances.  Lives in the same AWS account as prod for now;
# isolation is per-VPC + per-state-bucket.
###############################################################################

environment  = "dev"
profile      = "default"
state_bucket = "livehybrid-splunk-dev-terraform"

# Dev has its own Route53 zone — delegate splunk.dev.livehybrid.com at the
# registrar the same way as prod (NS records to the new zone).
create_dns             = true
dns_base_splunk_domain = "splunk.dev.livehybrid.com"

# Separate /24 from prod.
default_vpc_cidr      = "192.168.20.0/24"
default_subnet_a_cidr = "192.168.20.0/26"
default_subnet_b_cidr = "192.168.20.64/26"
default_subnet_c_cidr = "192.168.20.128/26"



###############################################################################
# Deployment model: dev runs the SOK (Splunk Operator for Kubernetes) path —
# eks + sok layers (SOK is the only deployment model).
# No hybrid edge tier in dev (no HFs deployed, no dev AMI baked).
# sok_accept_splunk_general_terms is MANDATORY for Splunk 10.x containers:
# https://www.splunk.com/en_us/legal/splunk-general-terms.html
###############################################################################
sok_accept_splunk_general_terms = "--accept-sgt-current-at-splunk-com"

# Env-scoped secrets (SEC-1): dev pods hold DEV credentials only — never the
# prod-shared /monitoring/splunk/password + /splunk/pass4SymmKey. Takes effect
# at the next rebuild (the cluster re-forms with these; the dev admin password
# then comes from /dev/splunk/password).
sok_secret_admin_password_id = "/dev/splunk/password"
sok_secret_pass4symmkey_id   = "/dev/splunk/pass4SymmKey"
sok_secret_license_id        = "/dev/splunk/license"
# Persistent HEC token (OPS-14): foundation creates/seeds /dev/splunk/hec_token
# (out of the nightly teardown); the sok layer reads it so the token is stable
# across rebuilds instead of regenerating each night.
sok_secret_hec_token_id = "/dev/splunk/hec_token"

# Dev has no VPC of its own: it shares this AWS account with prod, whose
# account layer created the single splunk VPC (tagged Name=prod) plus the
# default-{a,b,c} subnets the EKS nodes join. Point the eks layer's VPC
# discovery at it. (The full account layer can't apply a second time in this
# account — fixed-name resources like alias/pki-key and the default-* subnets
# would collide — so the persistent dev foundation the SOK path needs, the
# SmartStore bucket + KMS key, lives in the sok-foundation layer instead.)
eks_vpc_name_tag = "prod"

# Cluster + AWS-Console "Resources" access on the EKS cluster —
# authentication_mode=API trusts nobody implicitly, so grant admins explicitly.
# NB: a `:root` account ARN here is a no-op for kubectl/console — EKS access
# entries match the exact caller principal and do NOT expand root to every IAM
# identity, so list the real user/role ARNs that need admin.
eks_console_admin_principal_arns = [
  "arn:aws:iam::123456789012:user/car",
]

# Minimal single-node dev: with the 1-indexer S0a shape, one t3.xlarge (4 vCPU /
# 16 GiB) comfortably holds the indexer + CM/SH/LM/MC + operator (pods request
# 250m CPU each; operator requests are trimmed too). ~$0.17/hr of nodes on top of
# the $0.10/hr control plane. No autoscaler, so desired is what runs.
eks_node_groups = {
  general-a = {
    instance_type     = "t3.xlarge"
    desired           = 1
    min               = 1
    max               = 2 # desired=1 runs; max=2 leaves headroom for a node roll
    availability_zone = "eu-west-2a"
  }
}

# Same roles enabled as prod, but SHC suppressed (1 SH is fine for dev).
enable_shc = false

# S0a min-shape: a single indexer (RF=1/SF=1) to keep dev infra cost minimal.
# The operator MAY floor single-site clusters at 3 peers (docs: "minimum 3") —
# if it rejects/floors this, revert to replicas=3/RF=3/SF=2.
replication_factor   = 1
search_factor        = 1
sok_indexer_replicas = 1






trusted_cidrs = [
  "82.30.10.70/32",
  "147.161.224.0/23",
  "165.225.80.0/22",
  "147.161.166.0/23",
  "147.161.224.0/23",
  "165.225.16.0/23",
  "147.161.236.0/23",
  "165.225.196.0/23",
  "165.225.198.0/23",
]


# Flip to true once every node holds an internal-CA-issued cert (see README TLS section).

###############################################################################
# External Splunk Web (opt-in) — put an internet-facing ALB in front of the SOK
# Standalone search head's UI so it has a real HTTPS URL instead of
# `kubectl port-forward`. See docs "External access (Splunk Web via ALB)".
#
#   enabled   -> creates the ALB Ingress + a Route53 CNAME to it
#   hostname  -> must be covered by the *.splunk.livehybrid.com ACM cert
#   zone_name -> the Route53 public zone the CNAME lives in
#   allowed_cidrs (below, commented) -> inbound allow-list; EMPTY = trusted_cidrs
#                (82.30.10.70/32). Set ["0.0.0.0/0"] to open it to everyone.
#
# ⚠ These UIs are full admin on the cluster (login: admin, password from
#   /dev/splunk/password — env-scoped, SEC-1). Keep the allow-list narrow and
#   TEAR IT DOWN after use (set enabled=false + re-apply, or destroy the layer).
###############################################################################
sok_web_external_enabled   = true
sok_web_external_hostname  = "sok-dev.splunk.livehybrid.com"
sok_web_external_zone_name = "splunk.livehybrid.com"
# Which UIs ride the (single) ALB — sh keeps the hostname above; the others get
# sok-dev-<component>.splunk.livehybrid.com. Valid: sh, cm, lm, mc (+ deployer on
# SHC shapes). Indexers are never exposable. Adding/removing entries only edits
# ALB rules + DNS — no pod restarts.
sok_web_external_components = ["sh", "cm", "lm", "mc"]
# HEC on the same ALB at sok-dev-hec.splunk.livehybrid.com:443 -> indexer :8088
# (HTTPS backend, 7d sticky for useACK senders). NB: external senders must be
# within the allow-list (sok_web_external_allowed_cidrs / trusted_cidrs).
sok_hec_external_enabled = true
# sok_web_external_allowed_cidrs = ["0.0.0.0/0"]  # widen ONLY for the demo window, then revert

# CI (GitHub Actions) needs an EKS access entry to manage the sok layer —
# creator-admin only covers whoever CREATED the cluster (CI-built clusters
# have it implicitly; locally-built ones do not, which broke the first
# CI-driven dev destroy with k8s Unauthorized).
gh_actions_role_arn = "arn:aws:iam::123456789012:role/GitHubActionsTerraform"
