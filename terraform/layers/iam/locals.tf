data "aws_caller_identity" "current" {}
data "aws_iam_account_alias" "account" {}

locals {
  account_id   = data.aws_caller_identity.current.account_id
  account_name = data.aws_iam_account_alias.account.account_alias

  s3        = data.terraform_remote_state.account.outputs.s3
  kms       = data.terraform_remote_state.account.outputs.kms
  dns       = data.terraform_remote_state.account.outputs.dns
  vpcs      = data.terraform_remote_state.account.outputs.vpcs
  net       = data.terraform_remote_state.account.outputs.net
  sg_ids    = data.terraform_remote_state.account.outputs.sg_ids
  secrets   = data.terraform_remote_state.account.outputs.secrets
  endpoints = data.terraform_remote_state.account.outputs.endpoints
}
