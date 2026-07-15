data "aws_caller_identity" "current" {}

locals {
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

  # Subnet id list for the interface VPC endpoints (vpc_default_ep.tf).
  net_lists = {
    default = [
      aws_subnet.default_a.id,
      aws_subnet.default_b.id,
      aws_subnet.default_c.id,
    ]
  }
}
