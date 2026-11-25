terraform {
  backend "s3" {
    key     = "iam/terraform.tfstate"
    region  = "eu-west-2"
    encrypt = true
  }
}
