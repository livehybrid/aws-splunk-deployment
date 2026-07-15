###########################################################
############ ---- SECURITY GROUPS ONLY ---- ###############
############ ------ NO RULES PLEASE ------ ################
###########################################################
# Rules are added in the cluster layer alongside the role
# instantiations.  This file only declares the SG shells so
# IDs are stable across applies.

resource "aws_security_group" "splunk_indexer" {
  count       = var.enable_splunk_indexer
  name        = "splunk-indexer"
  description = "splunk indexer sg"
  vpc_id      = aws_vpc.default.id

  tags = {
    Name    = "splunk-indexer"
    source  = "terraform"
    project = "splunk"
  }
}

resource "aws_security_group" "splunk_manager" {
  count       = var.enable_splunk_manager
  name        = "splunk-manager"
  description = "splunk cluster manager sg"
  vpc_id      = aws_vpc.default.id

  tags = {
    Name    = "splunk-manager"
    source  = "terraform"
    project = "splunk"
  }
}

resource "aws_security_group" "splunk_manager_access" {
  count       = var.enable_splunk_manager
  name        = "splunk-manager-access"
  description = "ingress allow-list for the cluster manager mgmt port"
  vpc_id      = aws_vpc.default.id

  tags = {
    Name    = "splunk-manager-access"
    source  = "terraform"
    project = "splunk"
  }
}

resource "aws_security_group" "splunk_deployer" {
  count       = var.enable_splunk_deployer
  name        = "splunk-deployer"
  description = "splunk SHC deployer sg"
  vpc_id      = aws_vpc.default.id

  tags = {
    Name    = "splunk-deployer"
    source  = "terraform"
    project = "splunk"
  }
}

resource "aws_security_group" "splunk_monitoring_console" {
  count       = var.enable_splunk_monitoring_console
  name        = "splunk-monitoring-console"
  description = "splunk monitoring console sg"
  vpc_id      = aws_vpc.default.id

  tags = {
    Name    = "splunk-monitoring-console"
    source  = "terraform"
    project = "splunk"
  }
}

resource "aws_security_group" "splunk_license" {
  count       = var.enable_splunk_license
  name        = "splunk-license"
  description = "splunk license manager sg"
  vpc_id      = aws_vpc.default.id

  tags = {
    Name    = "splunk-license"
    source  = "terraform"
    project = "splunk"
  }
}

resource "aws_security_group" "splunk_searchhead" {
  count       = var.enable_splunk_searchhead
  name        = "splunk-searchhead"
  description = "splunk searchhead sg"
  vpc_id      = aws_vpc.default.id

  tags = {
    Name    = "splunk-searchhead"
    source  = "terraform"
    project = "splunk"
  }
}

resource "aws_security_group" "splunk_forwarder" {
  count       = var.enable_splunk_forwarder
  name        = "splunk-forwarder"
  description = "splunk heavy forwarder sg"
  vpc_id      = aws_vpc.default.id

  tags = {
    Name    = "splunk-forwarder"
    source  = "terraform"
    project = "splunk"
  }
}

resource "aws_security_group" "splunk_alb" {
  name        = "splunk-alb"
  description = "splunk-alb"
  vpc_id      = aws_vpc.default.id

  tags = {
    Name    = "splunk-alb"
    source  = "terraform"
    project = "splunk"
  }
}

# Consolidated Splunk Web ALB security group.
# Replaces splunk_searchhead_alb / splunk_manager_ui_alb / splunk_license_ui_alb
# / splunk_hec_alb / splunk_entry_alb. One ALB host-routes every Splunk-Web
# subdomain (manager., license., mc., search., hec.).
resource "aws_security_group" "splunk_web_alb" {
  count       = (var.enable_splunk_manager + var.enable_splunk_license + var.enable_splunk_searchhead + var.enable_splunk_forwarder) > 0 ? 1 : 0
  name        = "splunk-web-alb"
  description = "Splunk consolidated Web ALB (Splunk Web + HEC)"
  vpc_id      = aws_vpc.default.id

  tags = {
    Name    = "splunk-web-alb"
    source  = "terraform"
    project = "splunk"
  }
}

# Terraform SGs have no default egress — without these the ALB times out
# reaching every target (504 on all endpoints).
resource "aws_security_group_rule" "splunk_web_alb_egress_web" {
  count             = length(aws_security_group.splunk_web_alb)
  security_group_id = aws_security_group.splunk_web_alb[0].id
  type              = "egress"
  protocol          = "tcp"
  from_port         = 8000
  to_port           = 8000
  cidr_blocks       = [aws_vpc.default.cidr_block]
  description       = "Splunk Web targets"
}

resource "aws_security_group_rule" "splunk_web_alb_egress_hec" {
  count             = length(aws_security_group.splunk_web_alb)
  security_group_id = aws_security_group.splunk_web_alb[0].id
  type              = "egress"
  protocol          = "tcp"
  from_port         = 8088
  to_port           = 8088
  cidr_blocks       = [aws_vpc.default.cidr_block]
  description       = "HEC targets"
}
