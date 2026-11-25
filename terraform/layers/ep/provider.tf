provider "aws" {
  region  = var.region
  profile = var.profile

  default_tags {
    tags = merge(var.extra_default_tags, {
      Project     = "splunk"
      Service     = "edge-processor"
      Environment = var.environment
      Workspace   = terraform.workspace
      ManagedBy   = "terraform"
    })
  }
}

# Wired from the eks layer's outputs (known at plan time, no chicken-egg).
provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  proxy_url              = var.k8s_proxy_url != "" ? var.k8s_proxy_url : null

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", data.aws_eks_cluster.this.name, "--region", var.region, "--profile", var.profile]
  }
}

provider "helm" {
  kubernetes = {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
    proxy_url              = var.k8s_proxy_url != "" ? var.k8s_proxy_url : null

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", data.aws_eks_cluster.this.name, "--region", var.region, "--profile", var.profile]
    }
  }
}
