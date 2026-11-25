resource "aws_vpc" "default" {
  cidr_block           = var.default_vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  instance_tenancy     = "default"

  tags = {
    Name = "splunk-sok-${var.environment}"
  }
}

resource "aws_flow_log" "default" {
  count                = var.vpc_flow_log_s3_arn == "" ? 0 : 1
  log_destination_type = "s3"
  log_destination      = var.vpc_flow_log_s3_arn
  traffic_type         = "ALL"
  vpc_id               = aws_vpc.default.id
}

resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.default.id

  tags = {
    Name = "default"
  }
}

resource "aws_subnet" "default" {
  for_each = var.vpc_subnets

  vpc_id                  = aws_vpc.default.id
  cidr_block              = each.value
  availability_zone       = "${var.region}${each.key}"
  map_public_ip_on_launch = var.map_public_ip_on_launch

  tags = {
    Name = "default-${each.key}"
  }
}

resource "aws_route_table_association" "default" {
  for_each = aws_subnet.default

  subnet_id      = each.value.id
  route_table_id = aws_default_route_table.default.id
}

resource "aws_default_route_table" "default" {
  default_route_table_id = aws_vpc.default.default_route_table_id
  timeouts {
    create = "5m"
    update = "5m"
  }

  tags = {
    Name = "default-sok"
  }
}

resource "aws_route" "default_to_igw" {
  count                  = var.enable_internet_gateway ? 1 : 0
  route_table_id         = aws_default_route_table.default.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.default[0].id
}

resource "aws_network_acl" "custom" {
  vpc_id     = aws_vpc.default.id
  subnet_ids = [for s in aws_subnet.default : s.id]

  tags = {
    Name = "custom"
  }
}

resource "aws_network_acl_rule" "custom_auto" {
  network_acl_id = aws_network_acl.custom.id
  rule_action    = "allow"
  count          = length(local.default_vpc_nacl_rules)
  rule_number    = 500 + count.index
  egress         = local.default_vpc_nacl_rules[count.index]["egress"]
  protocol       = local.default_vpc_nacl_rules[count.index]["protocol"]
  cidr_block     = local.default_vpc_nacl_rules[count.index]["cidr_block"]
  from_port      = local.default_vpc_nacl_rules[count.index]["from_port"]
  to_port        = local.default_vpc_nacl_rules[count.index]["to_port"]
}

resource "aws_internet_gateway" "default" {
  count  = var.enable_internet_gateway ? 1 : 0
  vpc_id = aws_vpc.default.id

  tags = {
    Name = "default"
  }
}

# -- State moves from the pre-for_each layout ---------------------------------
# Subnets and their route-table associations were three hand-written resources
# (default_a/b/c); they are now one for_each over var.vpc_subnets. The internet
# gateway and its route became optional (count). These blocks let an existing
# deployment adopt the new addresses in place; without them the plan would
# replace every subnet, and everything running in them.

moved {
  from = aws_subnet.default_a
  to   = aws_subnet.default["a"]
}

moved {
  from = aws_subnet.default_b
  to   = aws_subnet.default["b"]
}

moved {
  from = aws_subnet.default_c
  to   = aws_subnet.default["c"]
}

moved {
  from = aws_route_table_association.default_to_a
  to   = aws_route_table_association.default["a"]
}

moved {
  from = aws_route_table_association.default_to_b
  to   = aws_route_table_association.default["b"]
}

moved {
  from = aws_route_table_association.default_to_c
  to   = aws_route_table_association.default["c"]
}

moved {
  from = aws_internet_gateway.default
  to   = aws_internet_gateway.default[0]
}

moved {
  from = aws_route.default_to_igw
  to   = aws_route.default_to_igw[0]
}
