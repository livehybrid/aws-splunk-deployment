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

# default_tags do NOT reach EC2 instances or EBS volumes launched from a
# launch template: the provider applies them to a resource's own tags, and
# tag_specifications (what the instance is tagged with at launch) is passed to
# EC2 verbatim. hashicorp/terraform-provider-aws#32328. Read them back here
# so the node groups below can forward them explicitly.
data "aws_default_tags" "current" {}

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

  endpoint_public_access       = var.eks_enable_public_access
  endpoint_public_access_cidrs = var.eks_enable_public_access ? local.public_access_cidrs : []
  endpoint_private_access      = var.eks_enable_private_access

  authentication_mode = "API"

  # We create the IRSA OIDC provider ourselves (aws_iam_openid_connect_provider.this
  # below). The module still creates its OWN at 21.24.0 — enable_irsa defaults to
  # true — and an IAM OIDC provider is unique per URL per account, so leaving both
  # on races two CreateOpenIDConnectProvider calls for the same cluster issuer:
  #   ConcurrentModification: The previous tagging operation is still ongoing
  # on the first apply, then on every retry
  #   EntityAlreadyExists: Provider with url https://oidc.eks.<region>.amazonaws.com/id/... already exists
  # module.eks.oidc_provider (the issuer host string) is derived from the cluster,
  # not from this resource, so it keeps working with irsa off.
  enable_irsa = false

  # Do NOT auto-grant the creating principal admin. When dev is brought up by the
  # CI role (github_actions) via the SOK START workflow, this auto-created creator
  # access entry is for the SAME principal as the explicit `github_actions` entry
  # below, so the second CreateAccessEntry fails with 409 ResourceInUseException
  # (only bites CI-created clusters; a human-created cluster has a different
  # creator, which is why prod worked). Access is defined entirely by the
  # terraform-managed access_entries (github_actions + console admins), consistent
  # with authentication_mode=API granting nobody implicitly.
  # NB: every human admin must be listed in eks_console_admin_principal_arns.

  # TODO - Strictly speaking if this is going to be created by a service account it should be false?
  enable_cluster_creator_admin_permissions = true

  # Access entries are managed outside this module (see the aws_eks_access_policy_association
  # + null_resource.access_entry_guard below). With authentication_mode=API the entries are
  # the only thing granting cluster access, and losing one mid-destroy leaves node groups in
  # DELETE_FAILED (AccessDenied).
  #
  # ⚠ CORRECTION: an earlier version of this comment claimed standalone resources are
  # destroyed AFTER the module. They are not. Terraform destroys DEPENDENTS FIRST, and a
  # standalone resource referencing module.eks.cluster_name depends on the module, so it is
  # torn down BEFORE the node groups. That is exactly why
  # null_resource.access_entry_guard exists (see its note): it depends_on module.eks so its
  # destroy provisioner fires first and re-creates the entries the module still needs.
  #
  # Note this does NOT cover the node role. Its EC2_LINUX access entry is created
  # server-side by EKS, not here, and the AccessDenied seen on node-group deletes comes
  # from a different race: terraform-aws-eks puts no ordering edge between
  # aws_eks_node_group.this and aws_iam_role_policy_attachment.this (both only reference
  # the node role), so a destroy can detach AmazonEKSWorkerNodePolicy while the group is
  # still draining. Destroy node groups in their own phase to avoid it:
  #   terraform destroy -target='module.eks.module.eks_managed_node_group'
  #   terraform destroy
  # scripts/unblock.sh recovers a cluster already stuck this way.
  access_entries = {}

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
      # Per group (default ON_DEMAND). Keep stateful indexers on-demand; Spot suits
      # a throwaway dev pool. Replaces the old global use_spot toggle.
      capacity_type = ng.capacity_type

      desired_size = ng.desired
      min_size     = ng.min
      max_size     = ng.max

      subnet_ids = [local.subnet_by_az[ng.availability_zone]]

      # Node role owned OUTSIDE the module (see aws_iam_role.node below) purely to
      # fix destroy ordering. Consuming it via terraform_data.node_role gives the
      # node groups a graph edge to the policy attachments, which the module does
      # not create for its own role.
      create_iam_role = false
      iam_role_arn    = terraform_data.node_role.output

      # Tag what the launch template launches, not just the template itself.
      # Instances and volumes otherwise carry only Name, invisible to cost
      # allocation and tag-based policy. ⚠ Changing these tags creates a new
      # launch template version, which ROLLS the node group.
      tag_specifications = ["instance", "volume"]

      launch_template_tags = data.aws_default_tags.current.tags

      cloudinit_pre_nodeadm = concat(
        [
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
          },
        ],
        # NVMe instance-store (e.g. i7i): assemble all drives into a RAID-0
        # at /mnt/k8s-disks BEFORE nodeadm runs, so local-path-provisioner
        # (sok layer) finds the mount ready when it provisions PVCs.
        #
        # WHY NOT localStorage: RAID0 (NodeConfig): that strategy mounts the
        # RAID as the containerd/kubelet root filesystem, not as a separate
        # data volume. The PVC host path (/mnt/k8s-disks) then falls back to
        # a directory on the root EBS (~20 GB), not the RAID.
        #
        # Device discovery: instance-store NVMe disks appear as
        # /dev/nvme*n1 under AL2023. The root EBS volume is the one whose
        # serial number starts with "vol" (EC2 stamps vol-<id> into the
        # NVMe identify namespace). All other nvme*n1 devices are
        # instance-store and become RAID members.
        ng.nvme_local_storage ? [
          {
            content_type = "text/x-shellscript; charset=\"us-ascii\""
            content      = file("${path.module}/files/nvme-raid.sh")
          }
        ] : []
      )

      # IMDSv2 is enforced on this account; hop limit must be 2 so the EKS
      # image credential provider (running inside the container runtime) can
      # reach IMDS to obtain ECR credentials. Default hop limit of 1 drops
      # the request before it exits the container, causing 403 on image pulls.
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 2
      }

      labels = merge(ng.labels,
        { "splunk-sok/node-group" = name },
        ng.role != "" ? { "splunk-sok/role" = ng.role } : {}
      )

      taints = ng.role != "" ? {
        "splunk-sok/role" = {
          key    = "splunk-sok/role"
          value  = ng.role
          effect = "NO_SCHEDULE"
        }
      } : {}
    }
  }

  node_security_group_additional_rules = {
    egress_all = {
      description = "Allow all outbound (ECR image pulls, AWS API calls)"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "egress"
      cidr_blocks = ["0.0.0.0/0"]
    }
    # Node-to-node all traffic: pods on different nodes communicate directly
    # (kubelet health checks, CoreDNS, pod-to-pod). Without this, cross-node
    # UDP is silently dropped (e.g. node-local-dns -> CoreDNS on another node).
    ingress_self_all = {
      description = "Node to node all traffic"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
    # The EKS control plane calls admission webhooks on the nodes over HTTPS.
    # Without this the ALB controller webhook (port 9443) times out and every
    # Ingress/TargetGroupBinding create fails with "context deadline exceeded".
    #    ingress_control_plane_webhooks = {
    #      description                   = "Control plane to node webhooks (ALB controller)"
    #      protocol                      = "tcp"
    #      from_port                     = 9443
    #      to_port                       = 9443
    #      type                          = "ingress"
    #      source_cluster_security_group = true
    #    }
  }

  # A parked SOK deployment is destroyed nightly, never let cluster deletion
  # be blocked by lingering-resource protections we then have to hand-clean.
  deletion_protection = false

  tags = {
    "splunk-sok/deployment-model" = "sok"
  }
}

###############################################################################
# Node IAM role, owned HERE instead of by the module (create_iam_role = false on
# every node group above). This exists ONLY to fix destroy ordering.
#
# The bug: terraform-aws-eks creates no ordering edge between
# aws_eks_node_group.this and aws_iam_role_policy_attachment.this — both merely
# reference the node role — so they are siblings and `terraform destroy` tears
# them down IN PARALLEL. Detaching AmazonEKSWorkerNodePolicy while a node group
# is still draining makes EKS flag the group
#   "AccessDenied: Your worker nodes do not have access to the cluster"
# the delete fails, and EKS leaves the backing ASG with Terminate suspended, so
# every retry then dies on
#   "Couldn't terminate instances in ASG as Terminate process is suspended"
# and a plain re-run can never recover. Confirmed still true on module master,
# so bumping the pin does not help. (scripts/unblock.sh recovers a stuck cluster.)
#
# The fix: own the role and its attachments, then hand the module an ARN routed
# through terraform_data.node_role, which depends_on the attachments. That one
# edge makes the node groups DEPENDENTS of the attachments, and since Terraform
# destroys dependents first the order becomes deterministic:
#   node groups -> terraform_data.node_role -> policy attachments -> role
#
# Policy set is byte-for-byte what the module attached: its three defaults
# (WorkerNode, ECR read-only, CNI for ipv4) plus the two that were passed as
# iam_role_additional_policies. One shared role now serves all node groups
# instead of one role each; same policies, same trust.
###############################################################################

data "aws_iam_policy_document" "node_assume_role" {
  statement {
    sid     = "EKSNodeAssumeRole"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name_prefix        = "${local.cluster_name}-node-"
  assume_role_policy = data.aws_iam_policy_document.node_assume_role.json
  # Belt and braces for the same teardown: never let a lingering attachment block
  # the role delete once the node groups are gone.
  force_detach_policies = true
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = {
    # Module defaults (eks-managed-node-group/main.tf: iam_role_policy_prefix +
    # ipv4_cni_policy). cluster_ip_family is ipv4, so the IPv6 CNI policy is N/A.
    AmazonEKSWorkerNodePolicy          = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
    AmazonEC2ContainerRegistryReadOnly = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
    AmazonEKS_CNI_Policy               = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
    # Previously iam_role_additional_policies on each node group.
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    ecr_pull_through_cache       = aws_iam_policy.ecr_pull_through_cache.arn
  }

  role       = aws_iam_role.node.name
  policy_arn = each.value
}

# Ordering shim. The value IS just aws_iam_role.node.arn; routing it through a
# resource that depends_on the attachments is what creates the edge the module
# will not. Do not "simplify" this to a direct reference, that silently restores
# the parallel destroy.
resource "terraform_data" "node_role" {
  input = aws_iam_role.node.arn

  depends_on = [aws_iam_role_policy_attachment.node]
}

# IAM OIDC provider for IRSA, created here from the module's issuer URL and TLS
# fingerprint, and re-exposed (outputs.tf) so the sok layer's Splunk IRSA roles
# keep resolving it via remote state.
#
# ⚠ CORRECTION: an earlier version of this comment said v21 dropped the
# module-managed OIDC provider and its oidc_provider_arn output. It did not —
# 21.24.0 still has both (main.tf aws_iam_openid_connect_provider.oidc_provider,
# outputs.tf oidc_provider_arn), gated on enable_irsa, default true. Running both
# raced for the same issuer URL and broke apply; enable_irsa = false above is
# what makes this resource the only one. Do not remove that without deleting
# this resource, and vice versa.
#
# This also breaks the apply cycle that a module-output-based ARN caused: the
# EBS CSI role's trust doc read module.eks.oidc_provider_arn (a module OUTPUT)
# while the EBS CSI addon that consumes the role is created INSIDE module.eks (a
# module INPUT) -> module -> role -> module. The provider is now a standalone
# resource fed by module.eks.oidc_provider (a plain string), so the role no
# longer depends on a module output and the edge is gone.
# Root CA thumbprint for the provider above. Read HERE rather than via
# module.eks.cluster_tls_certificate_sha1_fingerprint, because that output is
# `try(data.tls_certificate.this[0]…, null)` and the module counts that data
# source on local.create_oidc_provider — i.e. on enable_irsa. With enable_irsa
# = false the output goes null and the provider fails with
#   Error: Null value found in list ... thumbprint_list
# Same URL, same certificates[0].sha1_fingerprint the module used, so the
# resulting provider is identical.
data "tls_certificate" "oidc" {
  url = "https://${module.eks.oidc_provider}"
}

resource "aws_iam_openid_connect_provider" "this" {
  url             = "https://${module.eks.oidc_provider}"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]

}

# IRSA role for the EBS CSI controller (dynamic gp3 provisioning for the
# Splunk etc/var PVCs).
data "aws_iam_policy_document" "ebs_csi_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.this.arn]
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

###############################################################################
# EKS access entries — managed OUTSIDE module.eks deliberately.
#
# With authentication_mode=API these entries are the only thing granting cluster
# access. If they live inside module.eks, Terraform destroys them in parallel
# with node groups on `terraform destroy` (no dependency edge between siblings).
# The node group delete calls the cluster API, which needs valid credentials —
# losing the access entry mid-destroy causes DELETE_FAILED (AccessDenied).
#
# Standalone resources at the root level have NO dependents on destroy, so
# Terraform always destroys the module (node groups → cluster) before destroying
# these. The entries are present for the entire node group deletion window.
#
# On create: these depend only on module.eks.cluster_name (a plain string), so
# they're created after the cluster exists. No change to apply ordering.
###############################################################################

locals {
  # Merge github_actions + console admin principals into one flat map.
  access_entry_principals = merge(
    var.gh_actions_role_arn == "" ? {} : {
      github_actions = var.gh_actions_role_arn
    },
    { for i, arn in var.eks_console_admin_principal_arns : "console_admin_${i}" => arn }
  )
}

#resource "aws_eks_access_entry" "admins" {
#  for_each = local.access_entry_principals
#
#  cluster_name  = module.eks.cluster_name
#  principal_arn = each.value
#  type          = "STANDARD"
#}

resource "aws_eks_access_policy_association" "admins" {
  for_each = local.access_entry_principals

  cluster_name  = module.eks.cluster_name
  principal_arn = each.value
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  # depends_on = [aws_eks_access_entry.admins]
}

# Destroy-time access entry guard.
#
# Problem: aws_eks_access_entry.admins has no dependency on module.eks internals
# (only on cluster_name, a plain string), so Terraform may destroy the access
# entries in parallel with node groups. Node group deletion calls the cluster API
# — losing the entry mid-destroy causes DELETE_FAILED (AccessDenied).
#
# Fix: this null_resource depends_on module.eks, which means on destroy it is
# scheduled BEFORE the module (dependents are destroyed first). Its destroy
# provisioner re-adds the access entry and policy so they are guaranteed to exist
# when Terraform then destroys the module's node groups.
resource "null_resource" "access_entry_guard" {
  for_each = local.access_entry_principals

  triggers = {
    cluster_name  = module.eks.cluster_name
    principal_arn = each.value
    region        = var.region
    profile       = var.profile
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOF
      aws eks create-access-entry \
        --cluster-name "${self.triggers.cluster_name}" \
        --principal-arn "${self.triggers.principal_arn}" \
        --type STANDARD \
        --region "${self.triggers.region}" \
        --profile "${self.triggers.profile}" 2>/dev/null || true
      aws eks associate-access-policy \
        --cluster-name "${self.triggers.cluster_name}" \
        --principal-arn "${self.triggers.principal_arn}" \
        --policy-arn "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy" \
        --access-scope type=cluster \
        --region "${self.triggers.region}" \
        --profile "${self.triggers.profile}" 2>/dev/null || true
    EOF
  }

  # depends_on module.eks so this resource is destroyed BEFORE the module on
  # `terraform destroy`, firing the provisioner while the cluster still exists.
  depends_on = [module.eks]
}