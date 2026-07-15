#TEMPORARY RULE TO ALLOW CONFIG
//resource "aws_security_group_rule" "license_ssh_from_trusted" {
//  count        = "${local.enable_splunk_license}"
//
//  description       = "to splunk ssh"
//  from_port         = 22
//  to_port           = 22
//  protocol          = "tcp"
//  security_group_id = "${local.sg_ids["splunk_license"]}"
//  type              = "ingress"
//  cidr_blocks       = ["${var.trusted_cidrs}"]
//}

# license:8000 from the consolidated splunk-web ALB. Trusted-CIDR 443 ingress
# to the ALB itself lives in splunk_web_alb.tf.

resource "aws_security_group_rule" "license_from_splunk_web_alb" {
  count                    = local.enable_splunk_license
  description              = "license 8000 from splunk-web ALB"
  from_port                = 8000
  to_port                  = 8000
  protocol                 = "tcp"
  security_group_id        = local.sg_ids["splunk_license"]
  type                     = "ingress"
  source_security_group_id = lookup(local.sg_ids, "splunk_web_alb", "")
}

//#No longer needed as using ALB
//resource "aws_security_group_rule" "license_http_from_trusted" {
//  count        = "${local.enable_splunk_license}"
//
//  description       = "to splunk http"
//  from_port         = 8000
//  to_port           = 8000
//  protocol          = "tcp"
//  security_group_id = "${local.sg_ids["splunk_license"]}"
//  type              = "ingress"
//  cidr_blocks       = ["${var.trusted_cidrs}"]
//}

#This is needed to send on to Splunk Cloud
resource "aws_security_group_rule" "license_fwd_to_www" {
  count = local.enable_splunk_license

  description       = "fwd to www"
  from_port         = 9997
  to_port           = 9997
  protocol          = "tcp"
  security_group_id = local.sg_ids["splunk_license"]
  type              = "egress"
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "license_from_www" {
  count = local.enable_splunk_license

  description       = "from www"
  from_port         = 443
  protocol          = "tcp"
  security_group_id = local.sg_ids["splunk_license"]
  to_port           = 443
  type              = "ingress"
  cidr_blocks       = ["0.0.0.0/0"]

}


resource "aws_security_group_rule" "license_8089_to_master" {
  count = local.enable_splunk_license * local.enable_splunk_manager

  description              = "to master"
  from_port                = 8089
  protocol                 = "tcp"
  security_group_id        = local.sg_ids["splunk_license"]
  to_port                  = 8089
  type                     = "egress"
  source_security_group_id = local.sg_ids["splunk_manager"]
}

resource "aws_security_group_rule" "license_8089_from_idx" {
  count = local.enable_splunk_license * local.enable_splunk_indexer

  description              = "from indexer"
  from_port                = 8089
  protocol                 = "tcp"
  security_group_id        = local.sg_ids["splunk_license"]
  to_port                  = 8089
  type                     = "ingress"
  source_security_group_id = local.sg_ids["splunk_indexer"]
}

resource "aws_security_group_rule" "license_8089_from_sh" {
  count = local.enable_splunk_license * local.enable_splunk_searchhead

  description              = "from searchhead"
  from_port                = 8089
  protocol                 = "tcp"
  security_group_id        = local.sg_ids["splunk_license"]
  to_port                  = 8089
  type                     = "ingress"
  source_security_group_id = local.sg_ids["splunk_searchhead"]
}

resource "aws_security_group_rule" "license_8089_from_hfwd" {
  count = local.enable_splunk_license * local.enable_splunk_forwarder

  description              = "from heavy fwd"
  from_port                = 8089
  protocol                 = "tcp"
  security_group_id        = local.sg_ids["splunk_license"]
  to_port                  = 8089
  type                     = "ingress"
  source_security_group_id = local.sg_ids["splunk_forwarder"]
}

resource "aws_security_group_rule" "license_8089_from_master" {
  count = local.enable_splunk_license * local.enable_splunk_manager

  description              = "from master"
  from_port                = 8089
  protocol                 = "tcp"
  security_group_id        = local.sg_ids["splunk_license"]
  to_port                  = 8089
  type                     = "ingress"
  source_security_group_id = local.sg_ids["splunk_manager"]
}

#Required for Lambda
resource "aws_security_group_rule" "license_to_www_https" {
  count = local.enable_splunk_license

  description       = "to www https"
  from_port         = 443
  protocol          = "tcp"
  security_group_id = local.sg_ids["splunk_license"]
  to_port           = 443
  type              = "egress"
  cidr_blocks       = ["0.0.0.0/0"]
}


# NLB (splunk-license-ha) health checks originate from VPC addresses, not a
# security group — without this the TG can never pass health checks.
resource "aws_security_group_rule" "license_8089_from_vpc_nlb" {
  count = local.enable_splunk_license

  description       = "splunkd from license-ha NLB health checks / VPCE clients"
  from_port         = 8089
  to_port           = 8089
  protocol          = "tcp"
  type              = "ingress"
  security_group_id = local.sg_ids["splunk_license"]
  cidr_blocks       = [lookup(local.vpcs["default"], "cidr")]
}
