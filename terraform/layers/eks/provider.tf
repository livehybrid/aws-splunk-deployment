provider "aws" {
  region  = var.region
  profile = var.profile

  default_tags {
    tags = {
      Project     = "splunk"
      Service     = "sok"
      Environment = var.environment
      Workspace   = terraform.workspace
      ManagedBy   = "terraform"
    }
  }
}

# This layer is PURE AWS INFRASTRUCTURE plus the two K8s objects the hashicorp
# kubernetes/helm providers can create in the same apply that builds the cluster
# (StorageClasses, the ALB controller), those providers tolerate an
# unknown-at-plan host and defer. The alekc/kubectl provider does NOT: it
# configures eagerly at plan and fails against a not-yet-existent API server, so
# ALL kubectl work (the CRDs) and the operator live in the sok layer, whose
# provider host comes from this layer's remote-state outputs (concrete at plan).
#
# Providers read module.eks.* directly (not a data source) so the endpoint/CA
# stay resolvable from state during the nightly destroy, when the K8s objects
# are torn down before the cluster.
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.cluster_name, "--region", var.region, "--profile", var.profile]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", local.cluster_name, "--region", var.region, "--profile", var.profile]
    }
  }
}
