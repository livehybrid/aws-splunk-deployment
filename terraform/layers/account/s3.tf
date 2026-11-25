###############################################################################
# S3 for the account layer.
#
# The persistent SOK buckets (SmartStore, apps, KV-backup) are defined in
# smartstore.tf / apps.tf / kvbackup.tf. This file only sets the policy on the
# out-of-band terraform-state bucket and the account-wide public-access block.
###############################################################################

# var.state_bucket, not a name derived from bucket_prefix: the backend bucket is
# created out of band and named independently, so a derived name only matched
# while bucket_prefix happened to agree with it. Any other prefix would have
# moved this policy onto a bucket that does not exist.
module "s3_policy_terraform" {
  source           = "../../modules/s3_bucket_policy"
  bucket_name      = var.state_bucket
  encrypted_bucket = true
  encryption_type  = "AES256"
}

resource "aws_s3_bucket_policy" "s3_terraform_policy" {
  bucket = var.state_bucket
  policy = module.s3_policy_terraform.json
}

resource "aws_s3_account_public_access_block" "block" {
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
