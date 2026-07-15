###############################################################################
# SOK layer — the Splunk half of deployment_model = "sok": global secret,
# IRSA, defaults ConfigMaps and the Splunk Enterprise custom resources.
#
# Own state key (NEVER reuse another layer's): sok/terraform.tfstate.
# Reads the eks layer's outputs; AWS foundation values (SmartStore bucket,
# KMS key) are discovered by naming convention — see the eks layer header.
#
# Nightly stop destroys THIS layer first (CRs, then PVCs while the CSI
# driver still exists), then the eks layer. PVC reclaimPolicy is Delete and
# CRs carry no delete-pvc finalizer: PVC deletion is explicit and ordered.
###############################################################################

terraform {
  backend "s3" {
    key     = "sok/terraform.tfstate"
    region  = "eu-west-2"
    encrypt = true
  }
}

data "terraform_remote_state" "eks" {
  backend   = "s3"
  workspace = var.environment

  config = {
    bucket  = var.state_bucket
    key     = "eks/terraform.tfstate"
    region  = var.region
    profile = var.profile
  }
}
