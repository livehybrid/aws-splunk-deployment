provider "aws" {
  region  = var.region
  profile = var.profile

  default_tags {
    tags = merge(var.extra_default_tags, {
      Project     = "splunk"
      Service     = "Splunk Operator for Kubernetes"
      Environment = var.environment
      Workspace   = terraform.workspace
      ManagedBy   = "terraform"
    })
  }
}

provider "random" {}
provider "external" {}
