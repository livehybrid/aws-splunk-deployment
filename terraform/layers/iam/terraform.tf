terraform {
  backend "s3" {
    key     = "iam/terraform.tfstate"
    region  = "eu-west-2"
    encrypt = true
  }
}

data "terraform_remote_state" "account" {
  backend   = "s3"
  workspace = var.environment

  config = {
    bucket  = var.state_bucket
    key     = "account/terraform.tfstate"
    region  = var.region
    profile = var.profile
  }
}
