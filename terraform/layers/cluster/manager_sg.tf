###############################################################################
# Cluster Manager security group rules.
#
# Ports:
#   8089 = splunkd management (CM ↔ peers, CM ↔ SHs, CM ↔ License Manager)
#   8000 = Splunk Web (via ALB)
#   443  = ALB to CM (via Splunk Web)
###############################################################################

# manager:8000 from the consolidated splunk-web ALB. Trusted-CIDR 443 ingress
# to the ALB itself lives in splunk_web_alb.tf (single rule, all roles).

resource "aws_security_group_rule" "manager_from_splunk_web_alb" {
  count                    = local.enable_splunk_manager
  description              = "manager 8000 from splunk-web ALB"
  from_port                = 8000
  to_port                  = 8000
  protocol                 = "tcp"
  security_group_id        = local.sg_ids["splunk_manager"]
  type                     = "ingress"
  source_security_group_id = lookup(local.sg_ids, "splunk_web_alb", "")
}

# 8089 mesh — egress from manager.

resource "aws_security_group_rule" "manager_8089_to_indexers" {
  count                    = local.enable_splunk_manager * local.enable_splunk_indexer
  description              = "manager 8089 to indexers"
  from_port                = 8089
  to_port                  = 8089
  protocol                 = "tcp"
  security_group_id        = local.sg_ids["splunk_manager"]
  type                     = "egress"
  source_security_group_id = local.sg_ids["splunk_indexer"]
}

resource "aws_security_group_rule" "manager_8089_to_sh" {
  count                    = local.enable_splunk_manager * local.enable_splunk_searchhead
  description              = "manager 8089 to SHs"
  from_port                = 8089
  to_port                  = 8089
  protocol                 = "tcp"
  security_group_id        = local.sg_ids["splunk_manager"]
  type                     = "egress"
  source_security_group_id = local.sg_ids["splunk_searchhead"]
}

resource "aws_security_group_rule" "manager_8089_to_license" {
  count                    = local.enable_splunk_manager * local.enable_splunk_license
  description              = "manager 8089 to license"
  from_port                = 8089
  to_port                  = 8089
  protocol                 = "tcp"
  security_group_id        = local.sg_ids["splunk_manager"]
  type                     = "egress"
  source_security_group_id = local.sg_ids["splunk_license"]
}

resource "aws_security_group_rule" "manager_8089_self" {
  count             = local.enable_splunk_manager
  description       = "manager 8089 self"
  from_port         = 8089
  to_port           = 8089
  protocol          = "tcp"
  security_group_id = local.sg_ids["splunk_manager"]
  type              = "egress"
  self              = true
}

# 8089 mesh — ingress to manager.

resource "aws_security_group_rule" "manager_from_8089_indexers" {
  count                    = local.enable_splunk_manager * local.enable_splunk_indexer
  description              = "manager 8089 from indexers"
  from_port                = 8089
  to_port                  = 8089
  protocol                 = "tcp"
  security_group_id        = local.sg_ids["splunk_manager"]
  type                     = "ingress"
  source_security_group_id = local.sg_ids["splunk_indexer"]
}

resource "aws_security_group_rule" "manager_from_8089_sh" {
  count                    = local.enable_splunk_manager * local.enable_splunk_searchhead
  description              = "manager 8089 from SHs"
  from_port                = 8089
  to_port                  = 8089
  protocol                 = "tcp"
  security_group_id        = local.sg_ids["splunk_manager"]
  type                     = "ingress"
  source_security_group_id = local.sg_ids["splunk_searchhead"]
}

resource "aws_security_group_rule" "manager_from_8089_license" {
  count                    = local.enable_splunk_manager * local.enable_splunk_license
  description              = "manager 8089 from license"
  from_port                = 8089
  to_port                  = 8089
  protocol                 = "tcp"
  security_group_id        = local.sg_ids["splunk_manager"]
  type                     = "ingress"
  source_security_group_id = local.sg_ids["splunk_license"]
}

resource "aws_security_group_rule" "manager_from_8089_forwarders" {
  count                    = local.enable_splunk_manager * local.enable_splunk_forwarder
  description              = "manager 8089 from heavy forwarders (indexer_discovery)"
  from_port                = 8089
  to_port                  = 8089
  protocol                 = "tcp"
  security_group_id        = local.sg_ids["splunk_manager"]
  type                     = "ingress"
  source_security_group_id = local.sg_ids["splunk_forwarder"]
}

resource "aws_security_group_rule" "manager_from_8089_self" {
  count             = local.enable_splunk_manager
  description       = "manager 8089 self"
  from_port         = 8089
  to_port           = 8089
  protocol          = "tcp"
  security_group_id = local.sg_ids["splunk_manager"]
  type              = "ingress"
  self              = true
}

# Outbound to the world (apt/dnf, git clone, Lambda PKI calls).
resource "aws_security_group_rule" "manager_to_www_https" {
  count             = local.enable_splunk_manager
  description       = "manager https out"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  security_group_id = local.sg_ids["splunk_manager"]
  type              = "egress"
  cidr_blocks       = ["0.0.0.0/0"]
}
