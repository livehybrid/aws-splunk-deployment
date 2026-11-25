###############################################################################
# Discovery + shared locals.
#
# The account foundation is discovered by the estate's naming conventions
# (see terraform.tf header for why remote state is deliberately not used):
#   - VPC:              tag Name = splunk-sok-<environment> (or eks_vpc_name_tag)
#   - subnets:          tag Name = default-{a,b,c} within that VPC
#   - SmartStore bucket: livehybrid-splunk-<env>-splunk-smartstore-<env>
#   - SmartStore KMS:    alias/splunk-smartstore-<env>-key
###############################################################################

locals {
  cluster_name = "splunk-sok-${lower(var.environment)}"

  # Public API access at rest is the trusted operator CIDRs; CI workflows pass
  # the runner's egress IP via eks_public_access_cidrs, APPENDED (not replacing)
  # so the same apply that creates the cluster can also reach the API to create
  # the StorageClasses + ALB controller (K2.1 / K5 start).
  public_access_cidrs = distinct(concat(var.trusted_cidrs, var.eks_public_access_cidrs))

  # Workspaces normally own their VPC and find it by name. To run a second
  # environment inside another's VPC (e.g. dev alongside prod in one account),
  # set eks_vpc_name_tag to that VPC's Name tag.
  # Uncomment the below if this is the case
  # vpc_name_tag = var.eks_vpc_name_tag != "" ? var.eks_vpc_name_tag : var.environment

  vpc_name_tag = var.eks_vpc_name_tag != "" ? var.eks_vpc_name_tag : "splunk-sok-${var.environment}"

  subnet_by_az = {
    "${var.region}a" = data.aws_subnet.default["a"].id
    "${var.region}b" = data.aws_subnet.default["b"].id
    "${var.region}c" = data.aws_subnet.default["c"].id
  }
  # Only the subnets that host a node group (+ the cluster needs >= 2 AZs for
  # the control plane ENIs, so always give it a+b).
  cluster_subnet_ids = [local.subnet_by_az["${var.region}a"], local.subnet_by_az["${var.region}b"]]
}

data "aws_vpc" "this" {
  tags = {
    Name = local.vpc_name_tag
  }
}

data "aws_subnet" "default" {
  for_each = toset(["a", "b", "c"])
  vpc_id   = data.aws_vpc.this.id

  tags = {
    Name = "default-${each.key}"
  }
}
