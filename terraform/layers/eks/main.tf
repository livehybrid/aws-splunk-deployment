###############################################################################
# Discovery + shared locals.
#
# The account foundation is discovered by the estate's naming conventions
# (see terraform.tf header for why remote state is deliberately not used):
#   - VPC:              tag Name = <environment>, project = splunk
#   - subnets:          tag Name = default-{a,b,c} within that VPC
#   - SmartStore bucket: livehybrid-splunk-<env>-splunk-smartstore-<env>
#   - SmartStore KMS:    alias/splunk-smartstore-<env>-key
###############################################################################

locals {
  cluster_name = "splunk-sok-${var.environment}"

  # Public API access at rest is the trusted operator CIDRs; CI workflows pass
  # the runner's egress IP via eks_public_access_cidrs, APPENDED (not replacing)
  # so the same apply that creates the cluster can also reach the API to create
  # the StorageClasses + ALB controller (K2.1 / K5 start).
  public_access_cidrs = distinct(concat(var.trusted_cidrs, var.eks_public_access_cidrs))

  # Dev and prod share one AWS account with a single splunk VPC (tagged
  # Name=prod); dev overrides eks_vpc_name_tag="prod". A workspace that owns
  # its VPC leaves it empty and this falls back to the workspace name.
  vpc_name_tag = var.eks_vpc_name_tag != "" ? var.eks_vpc_name_tag : var.environment
}

data "aws_vpc" "this" {
  tags = {
    Name    = local.vpc_name_tag
    project = "splunk"
  }
}

data "aws_subnet" "default" {
  for_each = toset(["a", "b", "c"])
  vpc_id   = data.aws_vpc.this.id

  tags = {
    Name = "default-${each.key}"
  }
}

locals {
  subnet_by_az = {
    eu-west-2a = data.aws_subnet.default["a"].id
    eu-west-2b = data.aws_subnet.default["b"].id
    eu-west-2c = data.aws_subnet.default["c"].id
  }
  # Only the subnets that host a node group (+ the cluster needs >= 2 AZs for
  # the control plane ENIs, so always give it a+b).
  cluster_subnet_ids = [local.subnet_by_az["eu-west-2a"], local.subnet_by_az["eu-west-2b"]]
}
