variable "instance_profile_name" {}
variable "keypair_name" {}
variable "ami_id" {}

variable "dns" {
  type = map(any)
}

variable "vpcs" {
  type = map(any)
}

variable "net" {
  type = map(any)
}

variable "s3" {
  type = map(any)
}

variable "sg_ids" {
  type = map(any)
}

variable "sns" {
  type = map(any)
}

variable "default_instance_size" {
  default = "t2.large"
}

variable "instance_size" {
  default = "" #custom - override only
}

variable "extra_user_data" {
  default = ""
}

variable "role" {
}

variable "desired_count" {
  default = 1
}

variable "ebs_optimized" {
  default = false
}

variable "os_volume_size" {
  default = 40
}

variable "asg_max_size" {
  default     = 1
  description = "Usually 1 as we scale the number of ASG, not the ASG themselves..."
}

variable "asg_desired_size" {
  default = 1
}

variable "hot_disk_size" {
  default = 500
}

variable "cold_disk_size" {
  default = 2500
}

variable "checkpoint_disk_size" {
  default = 60
}

variable "attach_checkpoint_ebs" {
  default = 0
}
variable "associate_public_ip_address" {
  default = false
}

variable "target_group" {
  type    = list(any)
  default = []
}

variable "security_groups" {
  type = list(any)
}

variable "availability_zone" {}

## Splunk Settings
variable "httpport" {
  default = 8000
}


variable "mgmtHostPort" {
  default = 8089
}

variable "licensePort" {
  default = 8089
}

variable "pass4SymmKey" {
  default = ""
}

variable "replication_factor" {
  default = 1
}

variable "search_factor" {
  default = 1
}

# Multisite indexer clustering. When true the CM declares available_sites and
# site_* factors, peers/SHs pick up a [general] site (AZ-derived for peers,
# site0 = no affinity for SHs and forwarders).
variable "multisite" {
  default = false
}

variable "available_sites" {
  default = "site1,site2"
}

# Data volume filesystem for indexer cache / HF checkpoint volumes.
variable "data_volume_filesystem" {
  default = "xfs"
  validation {
    condition     = contains(["xfs", "ext4"], var.data_volume_filesystem)
    error_message = "data_volume_filesystem must be \"xfs\" or \"ext4\"."
  }
}

variable "site_replication_factor_origin" {
  default = 1
}

variable "site_replication_factor_total" {
  default = 2
}

variable "site_search_factor_origin" {
  default = 1
}

variable "site_search_factor_total" {
  default = 2
}

variable "replication_port" {
  default = 9887
}

variable "cn_name" {
  default = ""
}

variable "apps_git_repo" {
  default = ""
}

variable "enabled" {
  default = 1
}

variable "enable_splunk_indexers" {
  default     = 1
  description = "Used to determine if idx clustering should be enabled"
}

variable "create_elastic_ip" {
  default     = 0
  description = "Create a dedicated elastic IP for this host?"
}
variable "splunk_admin_username" {
  default = "splunkadmin"
}

variable "enable_shc" {
  description = "Pass-through from the calling layer to switch a SH between SHC and standalone mode."
  type        = bool
  default     = true
}

variable "custom_name" {
  default = ""
}

variable "sso_admin_ad_guid" {
  default = ""
}
variable "enable_fips" {
  default = "0"
}

variable "lb_attachments" {
  default = []
  type    = list(string)
}

variable "environment" {}

variable "region" {
  default = "eu-west-2"
}

variable "smartstore_bucket" {
  description = "S3 bucket for the SmartStore warm/cold tier. Empty disables SmartStore."
  default     = ""
}

variable "smartstore_kms_arn" {
  description = "KMS key ARN encrypting the SmartStore bucket."
  default     = ""
}

variable "use_spot" {
  description = "When true, launch instances as Spot (cheaper, can be reclaimed)."
  type        = bool
  default     = false
}
variable "health_check_type" {
  description = "ASG health check type: EC2 (default) or ELB. ELB replaces instances whose splunkd fails target-group checks; only enable once a role is stable."
  default     = "EC2"
}

variable "health_check_grace_period" {
  description = "Seconds after launch before health checks count — must cover Splunk bootstrap (install, cluster join, web up)."
  default     = 900
}

variable "ssl_verify_server_cert" {
  description = "Set sslVerifyServerCert in server.conf. Only enable once every node holds a cert issued by the internal CA (no self-signed fallbacks in the fleet)."
  type        = bool
  default     = false
}

variable "imds_http_tokens" {
  description = "IMDSv2 enforcement. Indexers need \"optional\": Splunk 10.4's SmartStore S3 client fails to fetch instance-role creds via IMDSv2 (works via curl, so it's the splunkd client) — revisit on Splunk upgrades."
  default     = "required"
}
