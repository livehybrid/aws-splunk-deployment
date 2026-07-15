data "aws_caller_identity" "current" {}

resource "null_resource" "nacl_construct_ssh" {
  count = length(var.trusted_cidrs)

  triggers = {
    egress     = false
    protocol   = "tcp"
    cidr_block = element(var.trusted_cidrs, count.index)
    from_port  = 22
    to_port    = 22
  }
}

locals {
  cloudtrail_metric_name_space = "CloudTrailMetrics"

  account_id = data.aws_caller_identity.current.account_id
  # Per-workspace prefix so prod and dev can co-exist in one AWS account.
  account_name = "livehybrid-splunk-${var.environment}"

  # Base NACL rules for the default VPC.
  base_vpc_nacl_rules = [
    { egress = false, protocol = "tcp", cidr_block = "0.0.0.0/0", from_port = 443, to_port = 443 },    # https in
    { egress = false, protocol = "tcp", cidr_block = "0.0.0.0/0", from_port = 8089, to_port = 8089 },  # splunkd mgmt in
    { egress = false, protocol = "tcp", cidr_block = "0.0.0.0/0", from_port = 9997, to_port = 9997 },  # splunk2splunk in
    { egress = false, protocol = "tcp", cidr_block = "0.0.0.0/0", from_port = 1024, to_port = 65535 }, # ephemeral in
    { egress = false, protocol = "udp", cidr_block = "0.0.0.0/0", from_port = 5514, to_port = 5514 },  # syslog in
    { egress = true, protocol = "tcp", cidr_block = "0.0.0.0/0", from_port = 8089, to_port = 8089 },   # splunkd mgmt out
    { egress = true, protocol = "tcp", cidr_block = "0.0.0.0/0", from_port = 9997, to_port = 9997 },   # splunk out
    { egress = true, protocol = "tcp", cidr_block = "0.0.0.0/0", from_port = 80, to_port = 80 },       # http out
    { egress = true, protocol = "tcp", cidr_block = "0.0.0.0/0", from_port = 443, to_port = 443 },     # https out
    { egress = true, protocol = "tcp", cidr_block = "0.0.0.0/0", from_port = 1024, to_port = 65535 },  # ephemeral out
  ]

  default_vpc_nacl_rules = local.base_vpc_nacl_rules

  # Buckets the indexer/SH/HF instance roles need read+write access to via SSM/S3.
  s3_bucket_access = concat(
    [
      aws_s3_bucket.ma-certs.arn,
      "${aws_s3_bucket.ma-certs.arn}/*",
      aws_s3_bucket.resources.arn,
      "${aws_s3_bucket.resources.arn}/*",
      aws_s3_bucket.checkpoints.arn,
      "${aws_s3_bucket.checkpoints.arn}/*",
    ],
    var.enable_smartstore == 1 ? [
      aws_s3_bucket.splunk_smartstore[0].arn,
      "${aws_s3_bucket.splunk_smartstore[0].arn}/*",
    ] : [],
  )

  custom_s3_bucket_access   = var.custom_s3_bucket_access
  combined_s3_bucket_access = concat(local.s3_bucket_access, local.custom_s3_bucket_access)

  s3_vpce_permissions          = concat(tolist(["s3:ListAllMyBuckets"]), local.iam_s3_read_only_actions, local.iam_s3_list_bucket_actions)
  combined_s3_vpce_permissions = concat(var.custom_s3_vpce_permissions, local.s3_vpce_permissions)
}
