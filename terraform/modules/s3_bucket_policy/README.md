# s3_bucket_policy module

Reusable bucket-policy module that enforces encryption in transit and, optionally, a specific KMS key / SSE algorithm on a bucket.

<!-- BEGIN_TF_DOCS -->








## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_bucket_name"></a> [bucket\_name](#input\_bucket\_name) | n/a | `any` | n/a | yes |
| <a name="input_encrypted_bucket"></a> [encrypted\_bucket](#input\_encrypted\_bucket) | n/a | `bool` | `true` | no |
| <a name="input_encryption_type"></a> [encryption\_type](#input\_encryption\_type) | n/a | `string` | `"aws:kms"` | no |
| <a name="input_prevent_public_access"></a> [prevent\_public\_access](#input\_prevent\_public\_access) | n/a | `bool` | `true` | no |
| <a name="input_required_kms_arn"></a> [required\_kms\_arn](#input\_required\_kms\_arn) | n/a | `string` | `""` | no |
| <a name="input_ssl_access"></a> [ssl\_access](#input\_ssl\_access) | n/a | `bool` | `true` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_json"></a> [json](#output\_json) | n/a |
<!-- END_TF_DOCS -->
