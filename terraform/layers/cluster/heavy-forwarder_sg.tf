# forwarder:8088 from the consolidated splunk-web ALB (HEC). Trusted-CIDR 443
# ingress to the ALB itself lives in splunk_web_alb.tf.

resource "aws_security_group_rule" "forwarder_hec_from_splunk_web_alb" {
  count                    = local.enable_splunk_forwarder
  description              = "forwarder 8088 (HEC) from splunk-web ALB"
  from_port                = 8088
  to_port                  = 8088
  protocol                 = "tcp"
  security_group_id        = local.sg_ids["splunk_forwarder"]
  type                     = "ingress"
  source_security_group_id = lookup(local.sg_ids, "splunk_web_alb", "")
}


resource "aws_security_group_rule" "splunk_fwd_to_idx_9997" {
  count                    = local.enable_splunk_forwarder * local.enable_splunk_indexer
  description              = "to local indexers"
  from_port                = 9997
  protocol                 = "tcp"
  security_group_id        = local.sg_ids["splunk_forwarder"]
  to_port                  = 9998
  type                     = "egress"
  source_security_group_id = local.sg_ids["splunk_indexer"]
}

resource "aws_security_group_rule" "trusted_to_splunk_fwd_8088" {
  count             = local.enable_splunk_forwarder * (length(var.hec_trusted_cidrs) > 0 ? 1 : 0)
  description       = "to HEC direct from www"
  from_port         = 8088
  to_port           = 8088
  protocol          = "tcp"
  security_group_id = local.sg_ids["splunk_forwarder"]
  type              = "ingress"
  cidr_blocks       = var.hec_trusted_cidrs
}

resource "aws_security_group_rule" "www_to_splunk_fwd_9997" {
  count             = local.enable_splunk_forwarder
  description       = "to fwds from www"
  from_port         = 9997
  to_port           = 9998
  protocol          = "tcp"
  security_group_id = local.sg_ids["splunk_forwarder"]
  type              = "ingress"
  cidr_blocks       = ["0.0.0.0/0"]
}

# To DSP (Port 30001)
resource "aws_security_group_rule" "splunk_fwd_to_www_30001" {
  count             = local.enable_splunk_forwarder
  description       = "from fwds to dsp www"
  from_port         = 30001
  to_port           = 30001
  protocol          = "tcp"
  security_group_id = local.sg_ids["splunk_forwarder"]
  type              = "egress"
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "vpc_to_splunk_fwd_8088" {
  count             = local.enable_splunk_forwarder
  description       = "to hec from vpc"
  from_port         = 8088
  to_port           = 8088
  protocol          = "tcp"
  security_group_id = local.sg_ids["splunk_forwarder"]
  type              = "ingress"
  cidr_blocks       = [var.default_vpc_cidr]
}

resource "aws_security_group_rule" "splunk_fwd_to_www_9997" {
  count             = local.enable_splunk_forwarder
  description       = "to indexers on www"
  from_port         = 9997
  protocol          = "tcp"
  security_group_id = local.sg_ids["splunk_forwarder"]
  to_port           = 9998
  type              = "egress"
  cidr_blocks = [
    "0.0.0.0/0"
  ]
}
resource "aws_security_group_rule" "forwarder_to_8089_license" {
  count                    = local.enable_splunk_forwarder * local.enable_splunk_license
  description              = "to license"
  from_port                = 8089
  protocol                 = "tcp"
  security_group_id        = local.sg_ids["splunk_forwarder"]
  to_port                  = 8089
  type                     = "egress"
  source_security_group_id = local.sg_ids["splunk_license"]
}

resource "aws_security_group_rule" "forwarder_to_8089_www" {
  count             = local.enable_splunk_forwarder
  description       = "to www"
  from_port         = 8089
  protocol          = "tcp"
  security_group_id = local.sg_ids["splunk_forwarder"]
  to_port           = 8089
  type              = "egress"
  cidr_blocks = [
    "0.0.0.0/0"
  ]
}

resource "aws_security_group_rule" "forwarder_to_8089_master" {
  count                    = local.enable_splunk_forwarder * local.enable_splunk_manager
  description              = "to master"
  from_port                = 8089
  protocol                 = "tcp"
  security_group_id        = local.sg_ids["splunk_forwarder"]
  to_port                  = 8089
  type                     = "egress"
  source_security_group_id = local.sg_ids["splunk_manager_access"]
}

resource "aws_security_group_rule" "forwarder_to_ec2_endpoint" {
  count                    = local.enable_splunk_forwarder
  description              = "to ec2 endpoint"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = local.sg_ids["splunk_forwarder"]
  type                     = "egress"
  source_security_group_id = lookup(local.endpoints["ec2"], "sg_id")
}

#needed to get config from S3
resource "aws_security_group_rule" "forwarder_to_s3_endpoint" {
  count             = local.enable_splunk_forwarder
  description       = "to s3 endpoint"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  security_group_id = local.sg_ids["splunk_forwarder"]
  type              = "egress"
  prefix_list_ids   = [lookup(local.endpoints["s3"], "prefix_list_id")]
}

#needed to get to lambda
resource "aws_security_group_rule" "forwarder_to_www_https" {
  count             = local.enable_splunk_forwarder
  description       = "to www https"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  security_group_id = local.sg_ids["splunk_forwarder"]
  type              = "egress"
  cidr_blocks       = ["0.0.0.0/0"]
}

#needed to get to apt
resource "aws_security_group_rule" "forwarder_to_www_http" {
  count             = local.enable_splunk_forwarder
  description       = "to www http"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  security_group_id = local.sg_ids["splunk_forwarder"]
  type              = "egress"
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "port_8089_fwd_from_master" {
  count                    = local.enable_splunk_forwarder * local.enable_splunk_manager
  description              = "from master"
  from_port                = 8089
  protocol                 = "tcp"
  security_group_id        = local.sg_ids["splunk_forwarder"]
  to_port                  = 8089
  type                     = "ingress"
  source_security_group_id = local.sg_ids["splunk_manager"]
}

#Uncomment if running AWS TA app on forwarder!
//resource "aws_security_group_rule" "forwarder_to_sqs_endpoint" {
//  description              = "to sqs endpoint"
//  from_port                = 443
//  to_port                  = 443
//  protocol                 = "tcp"
//  security_group_id        = "${local.sg_ids["splunk_forwarder"]}"
//  type                     = "egress"
//  //prefix_list_ids = ["${lookup(local.endpoints["sqs"],"prefix_list_id")}"]
//  source_security_group_id = "${lookup(local.endpoints["sqs"],"sg_id")}"
//}


# The MC runs in the searchhead SG (monitoring_console.tf) and needs splunkd
# mgmt access to register HFs as distributed-search peers — without this its
# `add search-server` to forwarders fails silently.
resource "aws_security_group_rule" "forwarder_8089_from_searchhead_sg" {
  count = local.enable_splunk_forwarder * local.enable_splunk_monitoring_console

  description              = "splunkd mgmt from MC/SH tier (distributed search)"
  from_port                = 8089
  to_port                  = 8089
  protocol                 = "tcp"
  type                     = "ingress"
  security_group_id        = local.sg_ids["splunk_forwarder"]
  source_security_group_id = local.sg_ids["splunk_searchhead"]
}
