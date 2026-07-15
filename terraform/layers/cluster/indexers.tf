module "indexers_a" {
  source                 = "../../modules/splunk_instance"
  ssl_verify_server_cert = var.ssl_verify_server_cert
  role                   = "indexer"
  imds_http_tokens       = "optional" # Splunk 10.4 SmartStore S3 client cannot fetch creds via IMDSv2 (see module variable)
  multisite              = var.multisite
  data_volume_filesystem = var.data_volume_filesystem
  enabled                = local.enable_splunk_indexer

  environment           = var.environment
  use_spot              = var.use_spot
  ami_id                = var.splunk_ami
  keypair_name          = local.key_names["ops"]
  instance_profile_name = lookup(local.roles["splunk-indexer"], "instance_profile_name")
  splunk_admin_username = var.splunk_admin_username

  dns               = local.dns
  vpcs              = local.vpcs
  net               = local.net
  sg_ids            = local.sg_ids
  sns               = local.sns
  s3                = local.s3
  availability_zone = "eu-west-2a"
  cn_name           = var.pki_cn_name
  instance_size     = var.custom_instance_type_indexer
  os_volume_size    = "100"

  security_groups             = [local.sg_ids["splunk_indexer"]]
  associate_public_ip_address = true
  hot_disk_size               = var.indexer_cache_volume_size

  desired_count = local.enable_splunk_indexer * var.scale_splunk_indexer["eu-west-2a"]
  asg_max_size  = "1" // per-instance ASG; desired_count controls how many ASGs
}

module "indexers_b" {
  source                 = "../../modules/splunk_instance"
  ssl_verify_server_cert = var.ssl_verify_server_cert
  imds_http_tokens       = "optional" # Splunk 10.4 SmartStore S3 client cannot fetch creds via IMDSv2 (see module variable)
  multisite              = var.multisite
  data_volume_filesystem = var.data_volume_filesystem
  enabled                = local.enable_splunk_indexer

  role                  = "indexer"
  environment           = var.environment
  use_spot              = var.use_spot
  ami_id                = var.splunk_ami
  keypair_name          = local.key_names["ops"]
  instance_profile_name = lookup(local.roles["splunk-indexer"], "instance_profile_name")
  splunk_admin_username = var.splunk_admin_username

  dns               = local.dns
  vpcs              = local.vpcs
  net               = local.net
  sg_ids            = local.sg_ids
  sns               = local.sns
  s3                = local.s3
  availability_zone = "eu-west-2b"
  cn_name           = var.pki_cn_name
  instance_size     = var.custom_instance_type_indexer
  os_volume_size    = "100"

  security_groups             = [local.sg_ids["splunk_indexer"]]
  associate_public_ip_address = true
  hot_disk_size               = var.indexer_cache_volume_size

  desired_count = local.enable_splunk_indexer * var.scale_splunk_indexer["eu-west-2b"]
  asg_max_size  = "1" // per-instance ASG; desired_count controls how many ASGs
}

module "indexers_c" {
  source                 = "../../modules/splunk_instance"
  ssl_verify_server_cert = var.ssl_verify_server_cert
  imds_http_tokens       = "optional" # Splunk 10.4 SmartStore S3 client cannot fetch creds via IMDSv2 (see module variable)
  multisite              = var.multisite
  data_volume_filesystem = var.data_volume_filesystem
  enabled                = local.enable_splunk_indexer

  role                  = "indexer"
  environment           = var.environment
  use_spot              = var.use_spot
  ami_id                = var.splunk_ami
  keypair_name          = local.key_names["ops"]
  instance_profile_name = lookup(local.roles["splunk-indexer"], "instance_profile_name")
  splunk_admin_username = var.splunk_admin_username

  dns               = local.dns
  vpcs              = local.vpcs
  net               = local.net
  sg_ids            = local.sg_ids
  sns               = local.sns
  s3                = local.s3
  availability_zone = "eu-west-2c"
  cn_name           = var.pki_cn_name
  instance_size     = var.custom_instance_type_indexer
  os_volume_size    = "100"

  security_groups             = [local.sg_ids["splunk_indexer"]]
  associate_public_ip_address = true
  hot_disk_size               = var.indexer_cache_volume_size

  desired_count = local.enable_splunk_indexer * var.scale_splunk_indexer["eu-west-2c"]
  asg_max_size  = "1" // per-instance ASG; desired_count controls how many ASGs
}
