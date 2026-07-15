terraform {
  required_version = ">= 1.11, < 2.0"

  # This layer pins its own providers: terraform-aws-modules/eks v21 requires
  # AWS provider >= 6.0 while the rest of the repo is on ~> 5.80. Separate
  # layer = separate lockfile, so nothing else is upgraded.
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.16" # v2 keeps the kubernetes{} block syntax
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.33"
    }
    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = "~> 2.3"
    }
  }
}
