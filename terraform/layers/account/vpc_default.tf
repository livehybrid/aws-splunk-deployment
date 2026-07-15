resource "aws_vpc" "default" {
  cidr_block           = var.default_vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  instance_tenancy     = "default"

  tags = {
    Name    = var.environment
    source  = "terraform"
    project = "splunk"
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
    Name        = "default"
    Description = "default vpc default sg"
    source      = "terraform"
    project     = "splunk"
  }
}

resource "aws_subnet" "default_a" {
  vpc_id                  = aws_vpc.default.id
  cidr_block              = var.default_subnet_a_cidr
  availability_zone       = "eu-west-2a"
  map_public_ip_on_launch = true

  tags = {
    Name    = "default-a"
    source  = "terraform"
    project = "splunk"
  }
}

resource "aws_subnet" "default_b" {
  vpc_id                  = aws_vpc.default.id
  cidr_block              = var.default_subnet_b_cidr
  availability_zone       = "eu-west-2b"
  map_public_ip_on_launch = true

  tags = {
    Name    = "default-b"
    source  = "terraform"
    project = "splunk"
  }
}

resource "aws_subnet" "default_c" {
  vpc_id                  = aws_vpc.default.id
  cidr_block              = var.default_subnet_c_cidr
  availability_zone       = "eu-west-2c"
  map_public_ip_on_launch = true

  tags = {
    Name    = "default-c"
    source  = "terraform"
    project = "splunk"
  }
}

resource "aws_route_table_association" "default_to_a" {
  subnet_id      = aws_subnet.default_a.id
  route_table_id = aws_default_route_table.default.id
}

resource "aws_route_table_association" "default_to_b" {
  subnet_id      = aws_subnet.default_b.id
  route_table_id = aws_default_route_table.default.id
}

resource "aws_route_table_association" "default_to_c" {
  subnet_id      = aws_subnet.default_c.id
  route_table_id = aws_default_route_table.default.id
}

resource "aws_default_route_table" "default" {
  default_route_table_id = aws_vpc.default.default_route_table_id

  tags = {
    Name    = "default"
    source  = "terraform"
    project = "splunk"
  }
}

resource "aws_route" "default_to_igw" {
  route_table_id         = aws_default_route_table.default.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.default.id
}

resource "aws_network_acl" "custom" {
  vpc_id = aws_vpc.default.id
  subnet_ids = [
    aws_subnet.default_a.id,
    aws_subnet.default_b.id,
    aws_subnet.default_c.id,
  ]
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
  vpc_id = aws_vpc.default.id

  tags = {
    Name    = "default"
    source  = "terraform"
    project = "splunk"
  }
}


