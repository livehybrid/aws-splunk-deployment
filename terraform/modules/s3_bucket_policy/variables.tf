variable "encrypted_bucket" {
  default = true
}

variable "ssl_access" {
  default = true
}

variable "prevent_public_access" {
  default = true
}

variable "encryption_type" {
  default = "aws:kms" #or AES256
}

variable "required_kms_arn" {
  default = ""
}

variable "bucket_name" {}
