###############################################################################
# S3 for the account layer.
#
# The persistent SOK buckets (SmartStore, apps, KV-backup) are defined in
# smartstore.tf / apps.tf / kvbackup.tf. This file only sets the policy on the
# out-of-band terraform-state bucket and the account-wide public-access block.
###############################################################################

module "s3_policy_terraform" {
  source           = "../../modules/s3_bucket_policy"
  bucket_name      = "${local.account_name}-terraform"
  encrypted_bucket = true
  encryption_type  = "AES256"
}

resource "aws_s3_bucket_policy" "s3_terraform_policy" {
  bucket = "${local.account_name}-terraform"
  policy = module.s3_policy_terraform.json
}

resource "aws_s3_account_public_access_block" "block" {
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
