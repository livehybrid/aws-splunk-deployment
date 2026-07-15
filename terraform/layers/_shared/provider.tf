provider "aws" {
  region  = var.region
  profile = var.profile

  default_tags {
    tags = {
      Project     = "splunk"
      Service     = "c3"
      Environment = var.environment
      Workspace   = terraform.workspace
      ManagedBy   = "terraform"
    }
  }
}

# Cross-region provider alias for legacy ses-storage etc. — no longer in use
# but kept to avoid breaking any vestigial provider references.
provider "aws" {
  alias   = "eu-west-1"
  region  = "eu-west-1"
  profile = var.profile

  default_tags {
    tags = {
      Project     = "splunk"
      Service     = "c3"
      Environment = var.environment
      Workspace   = terraform.workspace
      ManagedBy   = "terraform"
    }
  }
}

provider "random" {}
provider "external" {}
