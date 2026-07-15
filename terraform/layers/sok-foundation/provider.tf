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
