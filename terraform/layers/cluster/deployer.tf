###############################################################################
# Splunk SHC Deployer — single instance, pushes apps to the SHC.
###############################################################################

module "deployer" {
  source                 = "../../modules/splunk_instance"
  ssl_verify_server_cert = var.ssl_verify_server_cert
  enabled                = local.enable_splunk_deployer

  environment           = var.environment
  use_spot              = var.use_spot
  ami_id                = var.splunk_ami
  keypair_name          = local.key_names["ops"]
  instance_profile_name = lookup(local.roles["splunk-deployer"], "instance_profile_name")
  apps_git_repo         = var.apps_git_repo
  splunk_admin_username = var.splunk_admin_username

  dns               = local.dns
  vpcs              = local.vpcs
  net               = local.net
  sg_ids            = local.sg_ids
  sns               = local.sns
  s3                = local.s3
  role              = "deployer"
  availability_zone = "eu-west-2a"
  cn_name           = var.pki_cn_name

  security_groups             = [local.sg_ids["splunk_searchhead"]]
  associate_public_ip_address = true
  instance_size               = var.custom_instance_type_deployer

  desired_count = "1"
  asg_max_size  = local.enable_splunk_deployer
}
