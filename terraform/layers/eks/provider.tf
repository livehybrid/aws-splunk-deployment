provider "aws" {
  region  = var.region
  profile = var.profile

  default_tags {
    tags = merge(var.extra_default_tags, {
      Project     = "splunk"
      Service     = "sok"
      Environment = var.environment
      Workspace   = terraform.workspace
      ManagedBy   = "terraform"
    })
  }
}

# The kubernetes and helm providers have been moved to the sok layer, which uses
# data.aws_eks_cluster.this (resolved at plan time against existing state) so
# provider init never races cluster creation. This layer is now pure AWS.
