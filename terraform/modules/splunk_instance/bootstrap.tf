resource "random_string" "splunk_internal_password" {
  length  = 12
  special = false
  count   = var.role == "license" ? 1 : 0
}

data "aws_secretsmanager_secret_version" "pass4SymmKey" {
  secret_id = "/splunk/pass4SymmKey"
}



locals {
  web_conf = templatefile("${path.module}/files/web_conf.tpl",
    {
      httpport     = var.httpport
      mgmtHostPort = var.mgmtHostPort
  })

  deploymentclient_conf = templatefile("${path.module}/files/deploymentclient_conf.tpl",
    {
      mgmtHostPort    = var.mgmtHostPort
      internal_domain = local.internal-domain
  })

  manager_idx_clustering = templatefile("${path.module}/files/snippets/manager_${var.enable_splunk_indexers == 1 ? "" : "no-"}idx_clustering.tpl",
    {
      pass4SymmKey                   = local.pass4SymmKey
      multisite                      = var.multisite
      available_sites                = var.available_sites
      replication_factor             = var.replication_factor
      search_factor                  = var.search_factor
      site_replication_factor_origin = var.site_replication_factor_origin
      site_replication_factor_total  = var.site_replication_factor_total
      site_search_factor_origin      = var.site_search_factor_origin
      site_search_factor_total       = var.site_search_factor_total
  })

  server_conf_template = templatefile("${path.module}/files/server_conf/${var.role}.tpl",
    {
      additional_config              = local.additional_server_conf
      multisite                      = var.multisite
      ssl_verify                     = var.ssl_verify_server_cert ? "true" : "false"
      internal_domain                = local.internal-domain
      master_port                    = var.mgmtHostPort
      license_port                   = var.licensePort
      pass4SymmKey                   = local.pass4SymmKey
      replication_port               = var.replication_port
      replication_factor             = var.replication_factor
      search_factor                  = var.search_factor
      site_replication_factor_origin = var.site_replication_factor_origin
      site_replication_factor_total  = var.site_replication_factor_total
      site_search_factor_origin      = var.site_search_factor_origin
      site_search_factor_total       = var.site_search_factor_total
      site                           = var.availability_zone == "eu-west-2a" ? "site1" : var.availability_zone == "eu-west-2b" ? "site2" : var.availability_zone == "eu-west-2c" ? "site3" : "unknownsite"
      env_name                       = var.environment
  })

  user_data = templatefile("${path.module}/files/bootstrap/${var.role}.tpl",
    {
      enable_fips                   = var.enable_fips
      enable_shc                    = var.enable_shc
      ssl_verify                    = var.ssl_verify_server_cert ? "true" : "false"
      deploymentclient_conf_content = contains(["manager", "deployer", "monitoring_console"], var.role) ? "" : local.deploymentclient_conf
      server_name                   = var.custom_name != "" ? replace(var.custom_name, "_", "-") : var.role
      server_conf_content           = local.server_conf_template
      web_conf_content              = local.web_conf
      internal_domain               = local.internal-domain
      fqdn                          = local.external-domain
      private_dns_zone              = lookup(local.dns["private"], "zone_id")
      public_dns_zone               = lookup(local.dns["public-splunk"], "zone_id")
      s3_resources_bucket           = lookup(var.s3["resources"], "name")
      s3_pki_bucket                 = lookup(var.s3["ma-certs"], "name")
      ca_name                       = var.cn_name
      pass4SymmKey                  = local.pass4SymmKey
      replication_port              = var.replication_port
      replication_factor            = var.replication_factor
      master_port                   = var.mgmtHostPort
      apps_git_repo                 = var.apps_git_repo
      splunk_admin_username         = var.splunk_admin_username
      internal_user_password        = var.role == "license" ? element(concat(random_string.splunk_internal_password.*.result, tolist([""])), 0) : ""
      attach_checkpoint_ebs         = var.attach_checkpoint_ebs
      sso_admin_ad_guid             = var.sso_admin_ad_guid
      smartstore_bucket             = var.smartstore_bucket
      smartstore_kms_arn            = var.smartstore_kms_arn
      data_filesystem               = var.data_volume_filesystem
      region                        = var.region
  })
}

//[deployment-client]
//serverRepositoryLocationPolicy = rejectAlways
//repositoryLocation = \$SPLUNK_HOME/etc/master-apps



data "cloudinit_config" "splunk" {

  gzip          = true
  base64_encode = true

  part {
    content_type = "text/cloud-config"

    content = <<CONTENT
#cloud-config
write_files:
  - content: |
      ${base64encode(var.extra_user_data)}
    encoding: b64
    owner: ec2-user:ec2-user
    path: /home/ec2-user/additional-bootstrap.sh
    permissions: '0744'
CONTENT
  }

  part {
    content_type = "text/x-shellscript"
    content      = local.user_data
  }
}
