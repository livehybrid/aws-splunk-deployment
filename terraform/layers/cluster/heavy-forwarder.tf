###############################################################################
# Heavy Forwarder tier — one ASG per AZ, attached to the public NLBs / HEC ALB.
#
# The number of HFs per AZ is set by scale_splunk_forwarder in the workspace
# tfvars; set an AZ to 0 to skip it (dev workspaces use single-AZ).
###############################################################################

module "heavy_forwarder_a" {
  source                 = "../../modules/splunk_instance"
  multisite              = var.multisite
  data_volume_filesystem = var.data_volume_filesystem
  ssl_verify_server_cert = var.ssl_verify_server_cert
  enabled                = local.enable_splunk_forwarder
  enable_splunk_indexers = local.enable_splunk_indexer

  custom_name           = "forwarder"
  role                  = "heavy-forwarder"
  create_elastic_ip     = 0
  environment           = var.environment
  use_spot              = var.use_spot
  ami_id                = var.splunk_ami
  keypair_name          = local.key_names["ops"]
  instance_profile_name = lookup(local.roles["splunk-forwarder"], "instance_profile_name")
  splunk_admin_username = var.splunk_admin_username

  dns               = local.dns
  vpcs              = local.vpcs
  net               = local.net
  sg_ids            = local.sg_ids
  sns               = local.sns
  s3                = local.s3
  availability_zone = "eu-west-2a"
  cn_name           = var.pki_cn_name
  instance_size     = var.custom_instance_type_heavy-forwarder

  security_groups = [
    local.sg_ids["splunk_forwarder"],
    local.sg_ids["splunk_manager_access"],
  ]

  associate_public_ip_address = true
  desired_count               = local.enable_splunk_forwarder * var.scale_splunk_forwarder["eu-west-2a"]
  asg_max_size                = "1"
  target_group                = local.hf_target_groups
}

module "heavy_forwarder_b" {
  source                 = "../../modules/splunk_instance"
  multisite              = var.multisite
  data_volume_filesystem = var.data_volume_filesystem
  ssl_verify_server_cert = var.ssl_verify_server_cert
  enabled                = local.enable_splunk_forwarder
  enable_splunk_indexers = local.enable_splunk_indexer

  custom_name           = "forwarder"
  role                  = "heavy-forwarder"
  create_elastic_ip     = 0
  environment           = var.environment
  use_spot              = var.use_spot
  ami_id                = var.splunk_ami
  keypair_name          = local.key_names["ops"]
  instance_profile_name = lookup(local.roles["splunk-forwarder"], "instance_profile_name")
  splunk_admin_username = var.splunk_admin_username

  dns               = local.dns
  vpcs              = local.vpcs
  net               = local.net
  sg_ids            = local.sg_ids
  sns               = local.sns
  s3                = local.s3
  availability_zone = "eu-west-2b"
  cn_name           = var.pki_cn_name
  instance_size     = var.custom_instance_type_heavy-forwarder

  security_groups = [
    local.sg_ids["splunk_forwarder"],
    local.sg_ids["splunk_manager_access"],
  ]

  associate_public_ip_address = true
  desired_count               = local.enable_splunk_forwarder * var.scale_splunk_forwarder["eu-west-2b"]
  asg_max_size                = "1"
  target_group                = local.hf_target_groups
}

module "heavy_forwarder_c" {
  source                 = "../../modules/splunk_instance"
  multisite              = var.multisite
  data_volume_filesystem = var.data_volume_filesystem
  ssl_verify_server_cert = var.ssl_verify_server_cert
  enabled                = local.enable_splunk_forwarder
  enable_splunk_indexers = local.enable_splunk_indexer

  custom_name           = "forwarder"
  role                  = "heavy-forwarder"
  create_elastic_ip     = 0
  environment           = var.environment
  use_spot              = var.use_spot
  ami_id                = var.splunk_ami
  keypair_name          = local.key_names["ops"]
  instance_profile_name = lookup(local.roles["splunk-forwarder"], "instance_profile_name")
  splunk_admin_username = var.splunk_admin_username

  dns               = local.dns
  vpcs              = local.vpcs
  net               = local.net
  sg_ids            = local.sg_ids
  sns               = local.sns
  s3                = local.s3
  availability_zone = "eu-west-2c"
  cn_name           = var.pki_cn_name
  instance_size     = var.custom_instance_type_heavy-forwarder

  security_groups = [
    local.sg_ids["splunk_forwarder"],
    local.sg_ids["splunk_manager_access"],
  ]

  associate_public_ip_address = true
  desired_count               = local.enable_splunk_forwarder * var.scale_splunk_forwarder["eu-west-2c"]
  asg_max_size                = "1"
  target_group                = local.hf_target_groups
}

output "heavy_forwarder_a_dns" {
  value = module.heavy_forwarder_a.dns
}

output "heavy_forwarder_b_dns" {
  value = module.heavy_forwarder_b.dns
}

output "heavy_forwarder_c_dns" {
  value = module.heavy_forwarder_c.dns
}
