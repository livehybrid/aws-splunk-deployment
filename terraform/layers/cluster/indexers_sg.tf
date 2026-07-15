resource "aws_security_group_rule" "port_9997_splunk_from_self" {
  count             = local.enable_splunk_indexer
  description       = "from self"
  self              = true
  from_port         = 9997
  protocol          = "tcp"
  security_group_id = local.sg_ids["splunk_indexer"]
  to_port           = 9997
  type              = "ingress"
}

resource "aws_security_group_rule" "port_9887_splunk_from_self" {
  count             = local.enable_splunk_indexer
  description       = "from self"
  self              = true
  from_port         = 9887
  protocol          = "tcp"
  security_group_id = local.sg_ids["splunk_indexer"]
  to_port           = 9887
  type              = "ingress"
}

resource "aws_security_group_rule" "port_9887_splunk_to_self" {
  count             = local.enable_splunk_indexer
  description       = "to self"
  self              = true
  from_port         = 9887
  protocol          = "tcp"
  security_group_id = local.sg_ids["splunk_indexer"]
  to_port           = 9887
  type              = "egress"
}

# SmartStore warm-bucket metadata replication (CMSendMetadataJob) posts to the
# target peer's management port. Without indexer<->indexer 8089 the CM can
# never meet RF/SF for buckets bootstrapped from the remote store (cold boot
# against a populated S3 bucket) — streaming on 9887 alone only covers hot
# bucket replication.
resource "aws_security_group_rule" "port_8089_indexers_from_self" {
  count             = local.enable_splunk_indexer
  description       = "from self (SmartStore bucket metadata replication)"
  self              = true
  from_port         = 8089
  protocol          = "tcp"
  security_group_id = local.sg_ids["splunk_indexer"]
  to_port           = 8089
  type              = "ingress"
}

resource "aws_security_group_rule" "port_8089_indexers_to_self" {
  count             = local.enable_splunk_indexer
  description       = "to self (SmartStore bucket metadata replication)"
  self              = true
  from_port         = 8089
  protocol          = "tcp"
  security_group_id = local.sg_ids["splunk_indexer"]
  to_port           = 8089
  type              = "egress"
}

resource "aws_security_group_rule" "port_8089_indexers_from_sh" {
  count                    = local.enable_splunk_indexer * local.enable_splunk_searchhead
  description              = "from search head"
  from_port                = 8089
  protocol                 = "tcp"
  security_group_id        = local.sg_ids["splunk_indexer"]
  to_port                  = 8089
  type                     = "ingress"
  source_security_group_id = local.sg_ids["splunk_searchhead"]
}

resource "aws_security_group_rule" "port_8089_indexers_from_master" {
  count                    = local.enable_splunk_indexer * local.enable_splunk_manager
  description              = "from master"
  from_port                = 8089
  protocol                 = "tcp"
  security_group_id        = local.sg_ids["splunk_indexer"]
  to_port                  = 8089
  type                     = "ingress"
  source_security_group_id = local.sg_ids["splunk_manager"]
}

resource "aws_security_group_rule" "port_9997_indexers_from_sh" {
  count                    = local.enable_splunk_indexer * local.enable_splunk_searchhead
  description              = "from search head"
  from_port                = 9997
  protocol                 = "tcp"
  security_group_id        = local.sg_ids["splunk_indexer"]
  to_port                  = 9997
  type                     = "ingress"
  source_security_group_id = local.sg_ids["splunk_searchhead"]
}

resource "aws_security_group_rule" "port_9997_indexers_from_master" {
  count                    = local.enable_splunk_indexer * local.enable_splunk_manager
  description              = "from master"
  from_port                = 9997
  protocol                 = "tcp"
  security_group_id        = local.sg_ids["splunk_indexer"]
  to_port                  = 9997
  type                     = "ingress"
  source_security_group_id = local.sg_ids["splunk_manager"]
}

resource "aws_security_group_rule" "port_9997_indexers_from_fwd" {
  count                    = local.enable_splunk_indexer * local.enable_splunk_forwarder
  description              = "from forwarder"
  from_port                = 9997
  protocol                 = "tcp"
  security_group_id        = local.sg_ids["splunk_indexer"]
  to_port                  = 9997
  type                     = "ingress"
  source_security_group_id = local.sg_ids["splunk_forwarder"]
}

//resource "aws_security_group_rule" "splunk_hec_alb_to_splunk" {
//  count                    = "${local.enable_splunk_forwarder}"
//  description              = "to splunk"
//  from_port                = 8088
//  protocol                 = "tcp"
//  security_group_id        = "${local.sg_ids["splunk_hec_alb"]}"
//  to_port                  = 8088
//  type                     = "egress"
//  source_security_group_id = "${local.sg_ids["splunk_forwarder"]}"
//}

resource "aws_security_group_rule" "port_8080_to_self" {
  count                    = local.enable_splunk_indexer
  description              = "to self"
  from_port                = 8080
  protocol                 = "tcp"
  security_group_id        = local.sg_ids["splunk_indexer"]
  to_port                  = 8080
  type                     = "egress"
  source_security_group_id = local.sg_ids["splunk_indexer"]
}

resource "aws_security_group_rule" "indexers_to_8089_license" {
  count                    = local.enable_splunk_indexer * local.enable_splunk_license
  description              = "to license"
  from_port                = 8089
  protocol                 = "tcp"
  security_group_id        = local.sg_ids["splunk_indexer"]
  to_port                  = 8089
  type                     = "egress"
  source_security_group_id = local.sg_ids["splunk_license"]
}

resource "aws_security_group_rule" "indexers_to_8089_master" {
  count                    = local.enable_splunk_indexer * local.enable_splunk_manager
  description              = "to master"
  from_port                = 8089
  protocol                 = "tcp"
  security_group_id        = local.sg_ids["splunk_indexer"]
  to_port                  = 8089
  type                     = "egress"
  source_security_group_id = local.sg_ids["splunk_manager"]
}

#Required for Lambda
resource "aws_security_group_rule" "indexers_to_www_https" {
  count             = local.enable_splunk_indexer
  description       = "to www https"
  from_port         = 443
  protocol          = "tcp"
  security_group_id = local.sg_ids["splunk_indexer"]
  to_port           = 443
  type              = "egress"
  cidr_blocks       = ["0.0.0.0/0"]
}

#Required for apt
resource "aws_security_group_rule" "indexers_to_www_http" {
  count             = local.enable_splunk_indexer
  description       = "to www http"
  from_port         = 80
  protocol          = "tcp"
  security_group_id = local.sg_ids["splunk_indexer"]
  to_port           = 80
  type              = "egress"
  cidr_blocks       = ["0.0.0.0/0"]
}
