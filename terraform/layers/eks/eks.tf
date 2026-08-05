###############################################################################
# The EKS cluster itself.
#
# Decisions (docs/kubernetes-sok-plan.md K2):
# - Nodes in the estate's existing PUBLIC subnets (the account layer has no
#   private subnets / NAT); SG-restricted, matching the EC2 posture.
# - Public API endpoint + authentication_mode API: GitHub-hosted runners must
#   reach the API for the nightly stop, and private endpoints take no CIDR
#   allowlist. At-rest CIDRs = trusted_cidrs; CI appends its egress IP per-run.
# - NO EKS Auto Mode (21-day forced node recycling, per-instance surcharge,
#   own EBS provisioner, all wrong for stateful indexers). No Spot.
# - AL2023 x86-64 nodes with THP disabled via pre-nodeadm user data: Splunk
#   documents >= 30% degradation with THP on, and the operator does not
#   manage node OS settings.
###############################################################################

module "eks" {
  source = "terraform-aws-modules/eks/aws"
  # Pinned EXACT (DEP-7): a floating ~> pin let every nightly rebuild pick up
  # whatever the module released that day, the opposite of the deterministic
  # rebuild the stop/start model assumes. Bump deliberately, with a plan.
  version = "21.24.0"

  name               = local.cluster_name
  kubernetes_version = var.eks_kubernetes_version

  vpc_id     = data.aws_vpc.this.id
  subnet_ids = local.cluster_subnet_ids

  endpoint_public_access       = true
  endpoint_public_access_cidrs = local.public_access_cidrs
  endpoint_private_access      = true

  authentication_mode = "API"
  # Do NOT auto-grant the creating principal admin. When dev is brought up by the
  # CI role (github_actions) via the SOK START workflow, this auto-created creator
  # access entry is for the SAME principal as the explicit `github_actions` entry
  # below, so the second CreateAccessEntry fails with 409 ResourceInUseException
  # (only bites CI-created clusters; a human-created cluster has a different
  # creator, which is why prod worked). Access is defined entirely by the
  # terraform-managed access_entries (github_actions + console admins), consistent
  # with authentication_mode=API granting nobody implicitly.
  # NB: every human admin must be listed in eks_console_admin_principal_arns.
  enable_cluster_creator_admin_permissions = false

  access_entries = merge(
    var.gh_actions_role_arn == "" ? {} : {
      github_actions = {
        principal_arn = var.gh_actions_role_arn
        policy_associations = {
          admin = {
            policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
            access_scope = {
              type = "cluster"
            }
          }
        }
      }
    },
    # Console/browse access, authentication_mode API grants nobody implicitly
    # (not even the account root). Terraform-managed so the grant survives the
    # nightly rebuild, unlike a hand-run `aws eks create-access-entry`.
    { for i, arn in var.eks_console_admin_principal_arns : "console_admin_${i}" => {
      principal_arn = arn
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    } }
  )

  # Addon versions pinned (DEP-7), the module defaults to most_recent, so an
  # unpinned nightly rebuild silently adopts whatever AWS published overnight.
  # These are the versions the 1.34 estate validated on (captured from the live
  # cluster); bump alongside kubernetes_version upgrades.
  addons = {
    coredns = {
      addon_version = "v1.13.2-eksbuild.11"
    }
    kube-proxy = {
      addon_version = "v1.34.6-eksbuild.13"
    }
    vpc-cni = {
      before_compute = true
      addon_version  = "v1.22.3-eksbuild.1"
      # NFR-5: the shared default-{a,b,c} subnets are /26s (~59 usable IPs each,
      # shared with the prod EC2 estate). The CNI default (warm ENI) hoards a
      # full ENI's worth of IPs (15 on t3.xlarge) per node; cap the warm pool so
      # a multi-node multisite shape can't exhaust a subnet. If the prod-shape
      # pod density ever outgrows this, the real fix is a secondary VPC CIDR +
      # CNI custom networking, see the runbook's IP-capacity note.
      configuration_values = jsonencode({
        # SEC-5: enables the aws-network-policy-agent so the splunk namespace's
        # NetworkPolicy objects (sok layer) are actually ENFORCED.
        enableNetworkPolicy = "true"
        env = {
          WARM_IP_TARGET    = "4"
          MINIMUM_IP_TARGET = "8"
        }
      })
    }
    aws-ebs-csi-driver = {
      service_account_role_arn = aws_iam_role.ebs_csi.arn
      addon_version            = "v1.62.0-eksbuild.1"
    }
  }

  eks_managed_node_groups = {
    for name, ng in var.eks_node_groups : name => {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = [ng.instance_type]
      capacity_type  = var.use_spot ? "SPOT" : "ON_DEMAND"

      desired_size = ng.desired
      min_size     = ng.min
      max_size     = ng.max

      subnet_ids = [local.subnet_by_az[ng.availability_zone]]

      # Beyond the module's default AmazonEC2ContainerRegistryReadOnly: pulling
      # THROUGH the account layer's ECR pull-through cache (ecr.tf, mirrors
      # public.ecr.aws) needs ecr:BatchImportUpstreamImage, and
      # ecr:CreateRepository since the cache auto-creates the private repo on
      # each image's first pull.
      iam_role_additional_policies = {
        ecr_pull_through_cache = aws_iam_policy.ecr_pull_through_cache.arn
      }

      cloudinit_pre_nodeadm = [
        {
          content_type = "text/x-shellscript; charset=\"us-ascii\""
          content      = file("${path.module}/files/node-prep.sh")
        },
        # Kubelet tuning for Splunk pods (credit: Gareth Anderson, SplunkTrust,
        # "SOK lessons from our implementation" pt2 + Splunk Lantern "Advanced
        # operational learnings"):
        #   singleProcessOOMKill: cgroupsv2 otherwise SIGKILLs the WHOLE pod
        #     process tree when one search OOMs, splunkd dies uncleanly (a
        #     SmartStore-corruption vector). K8s 1.32+ / EKS 1.34.
        #   shutdownGracePeriod: node-level graceful shutdown so splunkd gets
        #     time to stop on node termination (ASG churn, spot, upgrades).
        {
          content_type = "application/node.eks.aws"
          content      = <<-EOT
            apiVersion: node.eks.aws/v1alpha1
            kind: NodeConfig
            spec:
              kubelet:
                config:
                  singleProcessOOMKill: true
                  shutdownGracePeriod: 2m0s
                  shutdownGracePeriodCriticalPods: 30s
          EOT
        }
      ]

      labels = {
        "splunk.livehybrid.com/node-group" = name
      }
    }
  }

  # A parked SOK deployment is destroyed nightly, never let cluster deletion
  # be blocked by lingering-resource protections we then have to hand-clean.
  deletion_protection = false

  tags = {
    "splunk.livehybrid.com/deployment-model" = "sok"
  }
}

# IRSA role for the EBS CSI controller (dynamic gp3 provisioning for the
# Splunk etc/var PVCs).
data "aws_iam_policy_document" "ebs_csi_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${local.cluster_name}-ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_trust.json
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}
