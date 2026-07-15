terraform {
  backend "s3" {
    key     = "account/terraform.tfstate"
    region  = "eu-west-2"
    encrypt = true
  }
}

