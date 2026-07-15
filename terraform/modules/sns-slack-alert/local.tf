data "aws_caller_identity" "current" {}

locals {
  account_name = data.aws_caller_identity.current.account_id
}
