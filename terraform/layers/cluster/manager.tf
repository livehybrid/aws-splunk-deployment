###############################################################################
# Splunk Cluster Manager — single instance.
#
# Splunk does not support active-active cluster managers; HA is provided via
# regular config backups and restore-from-backup on an idle standby.
###############################################################################

resource "aws_eip" "manager" {
  count  = local.enable_splunk_manager
  domain = "vpc"

  tags = {
    Name = "splunk-manager-eip"
    host = "manager"
  }
}

module "manager" {
  source                 = "../../modules/splunk_instance"
  ssl_verify_server_cert = var.ssl_verify_server_cert
  enabled                = local.enable_splunk_manager
  enable_splunk_indexers = local.enable_splunk_indexer

  environment           = var.environment
  use_spot              = var.use_spot
  ami_id                = var.splunk_ami
  keypair_name          = local.key_names["ops"]
  instance_profile_name = lookup(local.roles["splunk-manager"], "instance_profile_name")
  apps_git_repo         = var.apps_git_repo
  splunk_admin_username = var.splunk_admin_username
  sso_admin_ad_guid     = var.sso_admin_ad_guid
  replication_factor    = var.replication_factor
  search_factor         = var.search_factor

  multisite                      = var.multisite
  available_sites                = var.available_sites
  site_replication_factor_origin = var.site_replication_factor_origin
  site_replication_factor_total  = var.site_replication_factor_total
  site_search_factor_origin      = var.site_search_factor_origin
  site_search_factor_total       = var.site_search_factor_total

  dns               = local.dns
  vpcs              = local.vpcs
  net               = local.net
  sg_ids            = local.sg_ids
  sns               = local.sns
  s3                = local.s3
  role              = "manager"
  availability_zone = "eu-west-2a"
  cn_name           = var.pki_cn_name

  security_groups             = [local.sg_ids["splunk_manager"]]
  associate_public_ip_address = true
  instance_size               = var.custom_instance_type_manager
  create_elastic_ip           = 0

  region             = var.region
  smartstore_bucket  = var.enable_smartstore == 1 ? lookup(local.s3["splunk-smartstore"], "name") : ""
  smartstore_kms_arn = var.enable_smartstore == 1 ? lookup(local.kms["splunk-smartstore"], "arn") : ""

  target_group  = tolist([element(concat(aws_lb_target_group.splunk_manager_ui.*.id, tolist([""])), 0)])
  desired_count = "1"
  asg_max_size  = local.enable_splunk_manager
}
