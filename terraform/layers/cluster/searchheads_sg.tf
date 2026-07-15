# searchhead:8000 from the consolidated splunk-web ALB. Trusted-CIDR 443
# ingress to the ALB itself lives in splunk_web_alb.tf.

resource "aws_security_group_rule" "searchhead_from_splunk_web_alb" {
  count                    = local.enable_splunk_searchhead
  description              = "searchhead 8000 from splunk-web ALB"
  from_port                = 8000
  to_port                  = 8000
  protocol                 = "tcp"
  security_group_id        = local.sg_ids["splunk_searchhead"]
  type                     = "ingress"
  source_security_group_id = lookup(local.sg_ids, "splunk_web_alb", "")
}

resource "aws_security_group_rule" "searchhead_kvstore_replication" {
  count             = local.enable_splunk_searchhead
  description       = "KV Store Replication"
  self              = true
  from_port         = 8191
  to_port           = 8191
  protocol          = "tcp"
  security_group_id = local.sg_ids["splunk_searchhead"]
  type              = "ingress"
}

resource "aws_security_group_rule" "searchhead_kvstore_replication_out" {
  count             = local.enable_splunk_searchhead
  description       = "KV Store Replication"
  self              = true
  from_port         = 8191
  to_port           = 8191
  protocol          = "tcp"
  security_group_id = local.sg_ids["splunk_searchhead"]
  type              = "egress"
}

resource "aws_security_group_rule" "searchhead_search_replication" {
  count             = local.enable_splunk_searchhead
  description       = "Search Replication"
  self              = true
  from_port         = 8181
  to_port           = 8181
  protocol          = "tcp"
  security_group_id = local.sg_ids["splunk_searchhead"]
  type              = "ingress"
}

#TEMPORARY RULE TO ALLOW CONFIG
//resource "aws_security_group_rule" "searchhead_ssh_from_trusted" {
//  count        = "${local.enable_splunk_searchhead}"
//  description       = "to splunk ssh"
//  from_port         = 22
//  to_port           = 22
//  protocol          = "tcp"
//  security_group_id = "${local.sg_ids["splunk_searchhead"]}"
//  type              = "ingress"
//  cidr_blocks       = ["${var.trusted_cidrs}"]
//}

resource "aws_security_group_rule" "sh_to_9997_indexers" {
  count                    = local.enable_splunk_searchhead * local.enable_splunk_indexer
  description              = "to indexers"
  from_port                = 9997
  protocol                 = "tcp"
  security_group_id        = local.sg_ids["splunk_searchhead"]
  to_port                  = 9997
  type                     = "egress"
  source_security_group_id = local.sg_ids["splunk_indexer"]
}

resource "aws_security_group_rule" "sh_to_8089_indexers" {
  count                    = local.enable_splunk_searchhead * local.enable_splunk_indexer
  description              = "to indexers"
  from_port                = 8089
  protocol                 = "tcp"
  security_group_id        = local.sg_ids["splunk_searchhead"]
  to_port                  = 8089
  type                     = "egress"
  source_security_group_id = local.sg_ids["splunk_indexer"]
}

resource "aws_security_group_rule" "sh_to_8089_master" {
  count                    = local.enable_splunk_searchhead * local.enable_splunk_manager
  description              = "to master"
  from_port                = 8089
  protocol                 = "tcp"
  security_group_id        = local.sg_ids["splunk_searchhead"]
  to_port                  = 8089
  type                     = "egress"
  source_security_group_id = local.sg_ids["splunk_manager"]
}

resource "aws_security_group_rule" "sh_to_8089_license" {
  count                    = local.enable_splunk_searchhead * local.enable_splunk_license
  description              = "to license"
  from_port                = 8089
  protocol                 = "tcp"
  security_group_id        = local.sg_ids["splunk_searchhead"]
  to_port                  = 8089
  type                     = "egress"
  source_security_group_id = local.sg_ids["splunk_license"]
}

resource "aws_security_group_rule" "sh_to_8089_self" {
  count             = local.enable_splunk_searchhead
  description       = "to self"
  from_port         = 8089
  protocol          = "tcp"
  security_group_id = local.sg_ids["splunk_searchhead"]
  to_port           = 8089
  type              = "egress"
  self              = true
}

resource "aws_security_group_rule" "sh_from_8089_self" {
  count             = local.enable_splunk_searchhead
  description       = "from self"
  from_port         = 8089
  protocol          = "tcp"
  security_group_id = local.sg_ids["splunk_searchhead"]
  to_port           = 8089
  type              = "ingress"
  self              = true
}

resource "aws_security_group_rule" "sh_from_8089_master" {
  count                    = local.enable_splunk_searchhead * local.enable_splunk_manager
  description              = "from master"
  from_port                = 8089
  protocol                 = "tcp"
  security_group_id        = local.sg_ids["splunk_searchhead"]
  to_port                  = 8089
  type                     = "ingress"
  source_security_group_id = local.sg_ids["splunk_manager"]
}

#Required for Lambda
resource "aws_security_group_rule" "sh_to_www_https" {
  count             = local.enable_splunk_searchhead
  description       = "to www https"
  from_port         = 443
  protocol          = "tcp"
  security_group_id = local.sg_ids["splunk_searchhead"]
  to_port           = 443
  type              = "egress"
  cidr_blocks       = ["0.0.0.0/0"]
}

#Required for apt
resource "aws_security_group_rule" "sh_to_www_http" {
  count             = local.enable_splunk_searchhead
  description       = "to www http"
  from_port         = 80
  protocol          = "tcp"
  security_group_id = local.sg_ids["splunk_searchhead"]
  to_port           = 80
  type              = "egress"
  cidr_blocks       = ["0.0.0.0/0"]
}


resource "aws_security_group_rule" "port_9887_splunkshc_from_self" {
  count             = local.enable_splunk_searchhead
  description       = "from self"
  self              = true
  from_port         = 9887
  protocol          = "tcp"
  security_group_id = local.sg_ids["splunk_searchhead"]
  to_port           = 9887
  type              = "ingress"
}

resource "aws_security_group_rule" "port_9887_splunkshc_to_self" {
  count             = local.enable_splunk_searchhead
  description       = "to self"
  self              = true
  from_port         = 9887
  protocol          = "tcp"
  security_group_id = local.sg_ids["splunk_searchhead"]
  to_port           = 9887
  type              = "egress"
}
# The MC runs in this SG and registers HFs as distributed-search peers —
# matching ingress exists on the forwarder SG (heavy-forwarder_sg.tf).
resource "aws_security_group_rule" "searchhead_to_8089_forwarder" {
  count = local.enable_splunk_searchhead * local.enable_splunk_forwarder

  description              = "splunkd mgmt to HFs (MC distributed search)"
  from_port                = 8089
  to_port                  = 8089
  protocol                 = "tcp"
  type                     = "egress"
  security_group_id        = local.sg_ids["splunk_searchhead"]
  source_security_group_id = local.sg_ids["splunk_forwarder"]
}
