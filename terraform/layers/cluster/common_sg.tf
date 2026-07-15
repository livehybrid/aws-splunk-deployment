resource "aws_security_group_rule" "common_to_ec2_endpoint" {
  count                    = var.environment == "audit" ? 1 : 0
  description              = "to ec2 endpoint"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = local.sg_ids["splunk_common"]
  type                     = "egress"
  source_security_group_id = lookup(local.endpoints["ec2"], "sg_id")
}

//resource "aws_security_group_rule" "common_to_sts_endpoint" {
//  description              = "to sts endpoint"
//  from_port                = 443
//  to_port                  = 443
//  protocol                 = "tcp"
//  security_group_id        = "${local.sg_ids["splunk_common"]}"
//  type                     = "egress"
//  source_security_group_id = "${lookup(local.endpoints["sts"],"sg_id")}"
//}

resource "aws_security_group_rule" "common_to_s3_endpoint" {
  count             = var.environment == "audit" ? 1 : 0
  description       = "to s3 endpoint"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  security_group_id = local.sg_ids["splunk_common"]
  type              = "egress"
  prefix_list_ids   = [lookup(local.endpoints["s3"], "prefix_list_id")]
}

resource "aws_security_group_rule" "common_to_sqs_endpoint" {
  count             = var.environment == "audit" ? 1 : 0
  description       = "to sqs endpoint"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  security_group_id = local.sg_ids["splunk_common"]
  type              = "egress"
  //prefix_list_ids = ["${lookup(local.endpoints["sqs"],"prefix_list_id")}"]
  source_security_group_id = lookup(local.endpoints["sqs"], "sg_id")
}



