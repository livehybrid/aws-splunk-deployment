data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  # S3 bucket names must be lower-case; lower() makes a mixed-case environment
  # value safe without renaming any existing bucket.
  environment = lower(var.environment)

  # Naming root for every account-layer bucket: <prefix>-splunk-<env>.
  # The sok layer derives the SAME root (sok/main.tf); keep the two in step.
  account_name = "${var.bucket_prefix}-splunk-${local.environment}"

  # Base NACL rules for the default VPC.
  base_vpc_nacl_rules = [
    { egress = false, protocol = "tcp", cidr_block = "0.0.0.0/0", from_port = 443, to_port = 443 },    # https in
    { egress = false, protocol = "tcp", cidr_block = "0.0.0.0/0", from_port = 8089, to_port = 8089 },  # splunkd mgmt in
    { egress = false, protocol = "tcp", cidr_block = "0.0.0.0/0", from_port = 9997, to_port = 9997 },  # splunk2splunk in
    { egress = false, protocol = "tcp", cidr_block = "0.0.0.0/0", from_port = 1024, to_port = 65535 }, # ephemeral in
    { egress = false, protocol = "udp", cidr_block = "0.0.0.0/0", from_port = 1024, to_port = 65535 }, # udp ephemeral in (return traffic for DNS etc)
    { egress = false, protocol = "udp", cidr_block = "0.0.0.0/0", from_port = 5514, to_port = 5514 },  # syslog in
    { egress = true, protocol = "tcp", cidr_block = "0.0.0.0/0", from_port = 8089, to_port = 8089 },   # splunkd mgmt out
    { egress = true, protocol = "tcp", cidr_block = "0.0.0.0/0", from_port = 9997, to_port = 9997 },   # splunk out
    { egress = true, protocol = "tcp", cidr_block = "0.0.0.0/0", from_port = 80, to_port = 80 },       # http out
    { egress = true, protocol = "tcp", cidr_block = "0.0.0.0/0", from_port = 443, to_port = 443 },     # https out
    { egress = true, protocol = "tcp", cidr_block = "0.0.0.0/0", from_port = 53, to_port = 53 },       # dns tcp out
    { egress = true, protocol = "udp", cidr_block = "0.0.0.0/0", from_port = 53, to_port = 53 },       # dns udp out
    { egress = true, protocol = "tcp", cidr_block = "0.0.0.0/0", from_port = 1024, to_port = 65535 },  # ephemeral out
    { egress = true, protocol = "udp", cidr_block = "0.0.0.0/0", from_port = 1024, to_port = 65535 },  # udp ephemeral out (node-local-dns -> coredns)
  ]

  default_vpc_nacl_rules = local.base_vpc_nacl_rules

  # Subnet id list for the interface VPC endpoints (vpc_default_ep.tf).
  net_lists = {
    default = [for s in aws_subnet.default : s.id]
  }
}
