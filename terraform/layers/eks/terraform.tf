###############################################################################
# EKS layer, the Kubernetes half of deployment_model = "sok".
#
# Own state key (NEVER reuse another layer's): eks/terraform.tfstate.
# This layer deliberately reads NO remote state. Dev and prod share one AWS
# account; the full account layer cannot apply a second time here (fixed-name
# resources would collide with the live prod estate, see the account
# layer header), so the VPC + subnets this layer needs are discovered via data
# sources by the estate's naming conventions (var.eks_vpc_name_tag +
# default-{a,b,c}) instead of account-layer outputs. The persistent SmartStore
# bucket + KMS the sok layer needs live in the account layer.
###############################################################################

terraform {
  backend "s3" {
    key     = "eks/terraform.tfstate"
    region  = "eu-west-2"
    encrypt = true
  }
}
