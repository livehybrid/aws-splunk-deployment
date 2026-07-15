variable "slack_channel" {
  default = ""
}
variable "name" {}
variable "lambda_role" {}
variable "enabled" {
  default = 1
}
variable "zip_output_file_mode" {
  description = "https://registry.terraform.io/providers/hashicorp/archive/latest/docs/data-sources/archive_file#output_file_mode"
  default     = "0777"
}