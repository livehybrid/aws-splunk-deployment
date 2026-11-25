variable "bucket_name" {}

variable "encrypted_bucket" {
  type    = bool
  default = true
}

variable "encryption_type" {
  type    = string
  default = "aws:kms"
}

variable "prevent_public_access" {
  type    = bool
  default = true
}

variable "required_kms_arn" {
  type    = string
  default = ""
}

variable "ssl_access" {
  type    = bool
  default = true
}
