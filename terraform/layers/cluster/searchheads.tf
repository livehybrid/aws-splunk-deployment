###############################################################################
# Search Head Cluster — 3 members (a/b/c) for prod, 1 standalone for dev.
#
# Dev should set scale_splunk_searchhead.{b,c} = 0 and enable_shc = false to
# collapse to a single standalone SH.
###############################################################################

module "searchheads_a" {
  source                 = "../../modules/splunk_instance"
  multisite              = var.multisite
  ssl_verify_server_cert = var.ssl_verify_server_cert
  role                   = "searchhead"
  enabled                = local.enable_splunk_searchhead

  environment           = var.environment
  use_spot              = var.use_spot
  ami_id                = var.splunk_ami
  keypair_name          = local.key_names["ops"]
  instance_profile_name = lookup(local.roles["splunk-sh"], "instance_profile_name")
  splunk_admin_username = var.splunk_admin_username
  os_volume_size        = "100"
  create_elastic_ip     = 0

  dns               = local.dns
  vpcs              = local.vpcs
  net               = local.net
  sg_ids            = local.sg_ids
  sns               = local.sns
  s3                = local.s3
  availability_zone = "eu-west-2a"
  cn_name           = var.pki_cn_name

  security_groups = [local.sg_ids["splunk_searchhead"]]

  associate_public_ip_address = true
  instance_size               = var.custom_instance_type_searchhead
  enable_shc                  = var.enable_shc
  region                      = var.region

  desired_count = local.enable_splunk_searchhead * var.scale_splunk_searchhead["eu-west-2a"]
  target_group  = [element(concat(aws_lb_target_group.splunk_searchheads.*.arn, tolist([""])), 0)]
}

module "searchheads_b" {
  source                 = "../../modules/splunk_instance"
  multisite              = var.multisite
  ssl_verify_server_cert = var.ssl_verify_server_cert
  role                   = "searchhead"
  enabled                = local.enable_splunk_searchhead

  environment           = var.environment
  use_spot              = var.use_spot
  ami_id                = var.splunk_ami
  keypair_name          = local.key_names["ops"]
  instance_profile_name = lookup(local.roles["splunk-sh"], "instance_profile_name")
  splunk_admin_username = var.splunk_admin_username
  os_volume_size        = "100"
  create_elastic_ip     = 0

  dns               = local.dns
  vpcs              = local.vpcs
  net               = local.net
  sg_ids            = local.sg_ids
  sns               = local.sns
  s3                = local.s3
  availability_zone = "eu-west-2b"
  cn_name           = var.pki_cn_name

  security_groups = [local.sg_ids["splunk_searchhead"]]

  associate_public_ip_address = true
  instance_size               = var.custom_instance_type_searchhead
  enable_shc                  = var.enable_shc
  region                      = var.region

  desired_count = local.enable_splunk_searchhead * var.scale_splunk_searchhead["eu-west-2b"]
  target_group  = [element(concat(aws_lb_target_group.splunk_searchheads.*.arn, tolist([""])), 0)]
}

module "searchheads_c" {
  source                 = "../../modules/splunk_instance"
  multisite              = var.multisite
  ssl_verify_server_cert = var.ssl_verify_server_cert
  role                   = "searchhead"
  enabled                = local.enable_splunk_searchhead

  environment           = var.environment
  use_spot              = var.use_spot
  ami_id                = var.splunk_ami
  keypair_name          = local.key_names["ops"]
  instance_profile_name = lookup(local.roles["splunk-sh"], "instance_profile_name")
  splunk_admin_username = var.splunk_admin_username
  os_volume_size        = "100"
  create_elastic_ip     = 0

  dns               = local.dns
  vpcs              = local.vpcs
  net               = local.net
  sg_ids            = local.sg_ids
  sns               = local.sns
  s3                = local.s3
  availability_zone = "eu-west-2c"
  cn_name           = var.pki_cn_name

  security_groups = [local.sg_ids["splunk_searchhead"]]

  associate_public_ip_address = true
  instance_size               = var.custom_instance_type_searchhead
  enable_shc                  = var.enable_shc
  region                      = var.region

  desired_count = local.enable_splunk_searchhead * var.scale_splunk_searchhead["eu-west-2c"]
  target_group  = [element(concat(aws_lb_target_group.splunk_searchheads.*.arn, tolist([""])), 0)]
}
