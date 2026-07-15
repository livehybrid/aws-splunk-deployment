terraform {
  required_version = ">= 1.11, < 2.0"

  # Matches the persistent estate layers (account/cluster/iam) — this is
  # account-foundation work, not part of the v6-pinned eks/sok layers.
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
