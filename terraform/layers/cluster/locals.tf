data "aws_caller_identity" "current" {}
data "aws_iam_account_alias" "account" {}

locals {
  account_id   = data.aws_caller_identity.current.account_id
  account_name = data.aws_iam_account_alias.account.account_alias

  s3        = data.terraform_remote_state.account.outputs.s3
  secrets   = data.terraform_remote_state.account.outputs.secrets
  kms       = data.terraform_remote_state.account.outputs.kms
  key_names = data.terraform_remote_state.account.outputs.key_names
  endpoints = data.terraform_remote_state.account.outputs.endpoints
  dns       = data.terraform_remote_state.account.outputs.dns
  vpcs      = data.terraform_remote_state.account.outputs.vpcs
  net       = data.terraform_remote_state.account.outputs.net
  net_lists = data.terraform_remote_state.account.outputs.net_lists
  sg_ids    = data.terraform_remote_state.account.outputs.sg_ids
  sns       = data.terraform_remote_state.account.outputs.sns

  roles = merge(
    data.terraform_remote_state.iam.outputs.roles,
    data.terraform_remote_state.account.outputs.roles,
  )

  cloudtrail_metric_name_space = "CloudTrailMetrics"

  heavy_fowarder_eips = concat(
    module.heavy_forwarder_a.ip,
    module.heavy_forwarder_b.ip,
    module.heavy_forwarder_c.ip,
  )

  # Target groups the HF ASGs register with. The HEC HF tier is collapsed into
  # this one — regular HFs serve HEC on :8088 via the splunk-web ALB.
  hf_target_groups = compact([
    element(concat(aws_lb_target_group.splunk_forwarder.*.arn, [""]), 0),
    element(concat(aws_lb_target_group.splunk_forwarder_internal.*.arn, [""]), 0),
    element(concat(aws_lb_target_group.splunk_heavy_forwarder.*.arn, [""]), 0),
    element(concat(aws_lb_target_group.splunk_forwarder_hec.*.arn, [""]), 0),
  ])
}
