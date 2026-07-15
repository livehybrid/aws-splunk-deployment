## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|:----:|:-----:|:-----:|
| account\_id | # AWScurrent account id | string | `"693466633220"` | no |
| additional\_sts\_roles |  | list | `<list>` | no |
| apps\_git\_repo |  | string | `""` | no |
| aws\_config\_aggregate |  | string | `"0"` | no |
| create\_dns |  | string | `"false"` | no |
| custom\_s3\_bucket\_access |  | list | `<list>` | no |
| default\_subnet\_a\_cidr |  | string | n/a | yes |
| default\_subnet\_b\_cidr |  | string | n/a | yes |
| default\_subnet\_c\_cidr |  | string | n/a | yes |
| default\_vpc\_cidr |  | string | n/a | yes |
| dns\_base\_domain |  | string | `"localhost"` | no |
| enable\_n3\_proxy\_endpoint |  | string | `"1"` | no |
| enable\_splunk\_forwarder |  | string | `"1"` | no |
| enable\_splunk\_indexer |  | string | `"1"` | no |
| enable\_splunk\_license |  | string | `"1"` | no |
| enable\_splunk\_master |  | string | `"1"` | no |
| enable\_splunk\_searchhead | Feature toggles | string | `"1"` | no |
| environment | # General | string | n/a | yes |
| license\_api\_trusted\_cidr | Additional access to License Server | list | `<list>` | no |
| management\_ami |  | string | `""` | no |
| oauth\_clientid |  | string | `""` | no |
| oauth\_clientsecret |  | string | `""` | no |
| oauth\_server |  | string | `""` | no |
| pki\_cn\_name |  | string | `"splunk.internal"` | no |
| profile |  | string | n/a | yes |
| region |  | string | `"eu-west-2"` | no |
| scale\_splunk\_forwarder | Scale toggles | map | `<map>` | no |
| scale\_splunk\_indexer |  | map | `<map>` | no |
| scale\_splunk\_license |  | map | `<map>` | no |
| scale\_splunk\_master |  | map | `<map>` | no |
| scale\_splunk\_searchhead |  | map | `<map>` | no |
| slack\_alerts\_channel |  | string | n/a | yes |
| splunk\_admin\_username |  | string | `"admin"` | no |
| splunk\_ami |  | string | `""` | no |
| splunkcloud\_fwd |  | string | `""` | no |
| ssl\_config |  | map | `<map>` | no |
| state\_bucket |  | string | n/a | yes |
| trusted\_cidrs | outbound cidr for trusted ips | list | `<list>` | no |

## Outputs

| Name | Description |
|------|-------------|
| dns |  |
| endpoints |  |
| key\_names |  |
| kms |  |
| net |  |
| net\_lists |  |
| root\_ca\_crt |  |
| s3 |  |
| secrets |  |
| sg\_ids |  |
| vpcs |  |

