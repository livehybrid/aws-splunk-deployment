## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|:----:|:-----:|:-----:|
| ami\_id |  | string | n/a | yes |
| apps\_git\_repo |  | string | `""` | no |
| asg\_desired\_size |  | string | `"1"` | no |
| asg\_max\_size | Usually 1 as we scale the number of ASG, not the ASG themselves... | string | `"1"` | no |
| associate\_public\_ip\_address |  | string | `"false"` | no |
| availability\_zone |  | string | n/a | yes |
| cn\_name |  | string | `""` | no |
| cold\_disk\_size |  | string | `"100"` | no |
| count |  | string | `"1"` | no |
| dns |  | map | n/a | yes |
| ebs\_optimized |  | string | `"false"` | no |
| enable\_splunk\_indexers | Used to determine if idx clustering should be enabled | string | `"1"` | no |
| enabled |  | string | `"1"` | no |
| environment |  | string | n/a | yes |
| extra\_user\_data |  | string | `""` | no |
| hot\_disk\_size |  | string | `"100"` | no |
| httpport | # Splunk Settings | string | `"8000"` | no |
| indexer\_volume\_size |  | string | `"50"` | no |
| instance\_profile\_name |  | string | n/a | yes |
| instance\_size |  | string | `"t2.large"` | no |
| keypair\_name |  | string | n/a | yes |
| mgmtHostPort |  | string | `"8089"` | no |
| net |  | map | n/a | yes |
| oauth\_clientid |  | string | `""` | no |
| oauth\_clientsecret |  | string | `""` | no |
| oauth\_server |  | string | `""` | no |
| os\_volume\_size |  | string | `"40"` | no |
| pass4SymmKey |  | string | `""` | no |
| region |  | string | `"eu-west-2"` | no |
| replication\_factor |  | string | `"1"` | no |
| replication\_port |  | string | `"9887"` | no |
| role |  | string | n/a | yes |
| s3 |  | map | n/a | yes |
| search\_factor |  | string | `"1"` | no |
| security\_groups |  | list | n/a | yes |
| sg\_ids |  | map | n/a | yes |
| splunk\_admin\_username |  | string | `"admin"` | no |
| splunkcloud\_fwd |  | string | `""` | no |
| target\_group |  | string | `""` | no |
| vpcs |  | map | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| asg\_id |  |

