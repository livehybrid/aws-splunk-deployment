# iam layer

The GitHubActionsTerraform OIDC CI role and its permissions boundary. The only IAM the SOK estate needs beyond the in-layer IRSA roles.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.11, < 2.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 5.80 |
| <a name="requirement_external"></a> [external](#requirement\_external) | ~> 2.3 |
| <a name="requirement_random"></a> [random](#requirement\_random) | ~> 3.6 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | 5.100.0 |
| <a name="provider_terraform"></a> [terraform](#provider\_terraform) | n/a |



## Resources

| Name | Type |
|------|------|
| [aws_iam_policy.gha_terraform_boundary](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_role.gha_terraform](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.gha_terraform_passrole](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy_attachment.gha_terraform_poweruser](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [terraform_data.backend_env_guard](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_openid_connect_provider.github](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_openid_connect_provider) | data source |
| [aws_iam_policy_document.gha_terraform_boundary](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.gha_terraform_passrole](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.gha_terraform_trust](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_available_sites"></a> [available\_sites](#input\_available\_sites) | n/a | `string` | `"site1,site2"` | no |
| <a name="input_create_dns"></a> [create\_dns](#input\_create\_dns) | n/a | `bool` | `false` | no |
| <a name="input_data_volume_filesystem"></a> [data\_volume\_filesystem](#input\_data\_volume\_filesystem) | Filesystem for indexer cache / HF checkpoint volumes ("xfs" or "ext4"). | `string` | `"xfs"` | no |
| <a name="input_default_subnet_a_cidr"></a> [default\_subnet\_a\_cidr](#input\_default\_subnet\_a\_cidr) | n/a | `any` | n/a | yes |
| <a name="input_default_subnet_b_cidr"></a> [default\_subnet\_b\_cidr](#input\_default\_subnet\_b\_cidr) | n/a | `any` | n/a | yes |
| <a name="input_default_subnet_c_cidr"></a> [default\_subnet\_c\_cidr](#input\_default\_subnet\_c\_cidr) | n/a | `any` | n/a | yes |
| <a name="input_default_vpc_cidr"></a> [default\_vpc\_cidr](#input\_default\_vpc\_cidr) | n/a | `any` | n/a | yes |
| <a name="input_dns_base_splunk_domain"></a> [dns\_base\_splunk\_domain](#input\_dns\_base\_splunk\_domain) | Internal (cluster-mesh) base domain for Splunk roles, e.g. internal.splunk.livehybrid.com. | `string` | `"splunk.internal"` | no |
| <a name="input_eks_cluster_dns_ip"></a> [eks\_cluster\_dns\_ip](#input\_eks\_cluster\_dns\_ip) | The kube-dns Service ClusterIP (.10 of the EKS service CIDR). Default matches EKS's default 10.100.0.0/16 service CIDR. node-local-dns binds this so it can transparently intercept pod DNS. Override only if the cluster uses a non-default service CIDR. | `string` | `"10.100.0.10"` | no |
| <a name="input_eks_console_admin_principal_arns"></a> [eks\_console\_admin\_principal\_arns](#input\_eks\_console\_admin\_principal\_arns) | IAM principal ARNs granted AmazonEKSClusterAdminPolicy via EKS access entries so the AWS Console can browse Kubernetes objects (authentication\_mode=API trusts NOBODY by default, not even root). Terraform-managed, so the grant survives the nightly rebuild. | `list(string)` | `[]` | no |
| <a name="input_eks_kubernetes_version"></a> [eks\_kubernetes\_version](#input\_eks\_kubernetes\_version) | EKS control-plane version. Coupled constraints (July 2026): SOK 3.1.0 supports K8s 1.25-1.34; K8s 1.34 requires Splunk >= 10.4 (IRSA token format). 1.34 exits standard EKS support 2026-12-02, after that the parked control plane bills 6x unless upgraded (needs a newer SOK release). | `string` | `"1.34"` | no |
| <a name="input_eks_node_groups"></a> [eks\_node\_groups](#input\_eks\_node\_groups) | Managed node groups, keyed by name. Splunk Enterprise images are x86-64 only and Splunk 10 requires AVX, no Graviton. Indexer nodes should be on-demand (no Spot for stateful pods). | <pre>map(object({<br/>    instance_type     = string<br/>    desired           = number<br/>    min               = number<br/>    max               = number<br/>    availability_zone = string<br/>  }))</pre> | <pre>{<br/>  "general-a": {<br/>    "availability_zone": "eu-west-2a",<br/>    "desired": 2,<br/>    "instance_type": "t3.xlarge",<br/>    "max": 3,<br/>    "min": 2<br/>  }<br/>}</pre> | no |
| <a name="input_eks_public_access_cidrs"></a> [eks\_public\_access\_cidrs](#input\_eks\_public\_access\_cidrs) | CIDRs allowed to reach the public EKS API endpoint. Empty = fall back to trusted\_cidrs. CI appends the runner egress IP for the duration of a run. | `list(string)` | `[]` | no |
| <a name="input_eks_vpc_name_tag"></a> [eks\_vpc\_name\_tag](#input\_eks\_vpc\_name\_tag) | Name tag of the (project=splunk) VPC the EKS nodes join. Dev and prod currently share one AWS account with a single splunk VPC tagged Name=prod, so the dev workspace points here at "prod". Empty = fall back to var.environment (a workspace that owns its VPC needs no override). The default-{a,b,c} subnets are then discovered within whichever VPC this resolves to. | `string` | `""` | no |
| <a name="input_enable_shc"></a> [enable\_shc](#input\_enable\_shc) | True for a 3-member Search Head Cluster; false for a standalone SH (dev). | `bool` | `true` | no |
| <a name="input_enable_vpc_endpoints"></a> [enable\_vpc\_endpoints](#input\_enable\_vpc\_endpoints) | Provision interface VPC endpoints (KMS, EC2, ELB, SSM, Logs, Events, Monitoring, SNS, SQS, ECR). Each costs ~$21/month across 3 AZs. Off by default: instances reach AWS APIs over the IGW. Turn on for private-subnet hardening. The S3 gateway endpoint is always on (free). | `bool` | `false` | no |
| <a name="input_environment"></a> [environment](#input\_environment) | Workspace name: prod, dev, etc. | `any` | n/a | yes |
| <a name="input_gh_actions_role_arn"></a> [gh\_actions\_role\_arn](#input\_gh\_actions\_role\_arn) | IAM role ARN used by GitHub Actions terraform workflows (repo variable AWS\_TERRAFORM\_ROLE\_ARN); granted an EKS admin access entry so CI can manage the sok layer. Empty = skip. | `string` | `""` | no |
| <a name="input_multisite"></a> [multisite](#input\_multisite) | Multisite indexer clustering (sites map to AZs: a=site1, b=site2, c=site3). When false, the site\_* factors are ignored and the cluster is single-site. | `bool` | `false` | no |
| <a name="input_profile"></a> [profile](#input\_profile) | Local AWS CLI profile to assume when applying. | `any` | n/a | yes |
| <a name="input_region"></a> [region](#input\_region) | n/a | `string` | `"eu-west-2"` | no |
| <a name="input_replication_factor"></a> [replication\_factor](#input\_replication\_factor) | n/a | `number` | `3` | no |
| <a name="input_search_factor"></a> [search\_factor](#input\_search\_factor) | n/a | `number` | `2` | no |
| <a name="input_site_replication_factor_origin"></a> [site\_replication\_factor\_origin](#input\_site\_replication\_factor\_origin) | n/a | `number` | `2` | no |
| <a name="input_site_replication_factor_total"></a> [site\_replication\_factor\_total](#input\_site\_replication\_factor\_total) | n/a | `number` | `3` | no |
| <a name="input_site_search_factor_origin"></a> [site\_search\_factor\_origin](#input\_site\_search\_factor\_origin) | n/a | `number` | `1` | no |
| <a name="input_site_search_factor_total"></a> [site\_search\_factor\_total](#input\_site\_search\_factor\_total) | n/a | `number` | `2` | no |
| <a name="input_sok_accept_splunk_general_terms"></a> [sok\_accept\_splunk\_general\_terms](#input\_sok\_accept\_splunk\_general\_terms) | Set to "--accept-sgt-current-at-splunk-com" to accept the Splunk General Terms (https://www.splunk.com/en_us/legal/splunk-general-terms.html). MANDATORY for Splunk 10.x containers under operator >= 3.0.0, pods refuse to start without it. Deliberately has no accepting default. | `string` | `""` | no |
| <a name="input_sok_alarm_notify_email"></a> [sok\_alarm\_notify\_email](#input\_sok\_alarm\_notify\_email) | Optional email subscribed to the SOK CloudWatch alarm SNS topic (NFR-2 CPU-credit alarm). Empty = topic created with no email subscription (subscribe a Lambda/AWS Chatbot to reach Slack, or add an address here). AWS emails a confirmation link that must be clicked once. | `string` | `""` | no |
| <a name="input_sok_alert_webhook_secret_id"></a> [sok\_alert\_webhook\_secret\_id](#input\_sok\_alert\_webhook\_secret\_id) | Secrets Manager id holding a Slack webhook URL for the in-cluster alert watchdog (OPS-4 option a). Empty = watchdog not deployed. Store it with: aws secretsmanager create-secret --name /monitoring/slack/webhook --secret-string '<url>'. | `string` | `""` | no |
| <a name="input_sok_cpucredit_low_threshold"></a> [sok\_cpucredit\_low\_threshold](#input\_sok\_cpucredit\_low\_threshold) | CPUCreditBalance below which the NFR-2 burstable-node alarm fires (min across an ASG's instances). 100 credits is ~2.7h of t3.large baseline runway (36 credits/hr), enough warning before throttling, high enough to ignore normal burst dips. Tune per node size. | `number` | `100` | no |
| <a name="input_sok_etc_storage"></a> [sok\_etc\_storage](#input\_sok\_etc\_storage) | Per-pod /opt/splunk/etc PVC size. The operator NEVER resizes PVCs, size generously. | `string` | `"10Gi"` | no |
| <a name="input_sok_etc_storage_by_role"></a> [sok\_etc\_storage\_by\_role](#input\_sok\_etc\_storage\_by\_role) | Per-role override of sok\_etc\_storage (NFR-6). Keys: cm, idxc, sh, shc, lm, mc; unset roles use the global. Empty (default) = uniform sizing. | `map(string)` | `{}` | no |
| <a name="input_sok_hec_external_enabled"></a> [sok\_hec\_external\_enabled](#input\_sok\_hec\_external\_enabled) | Expose HEC (indexer :8088, HTTPS) on the shared external ALB at <first-label>-hec.<zone>. REQUIRES sok\_web\_external\_enabled=true (the ALB, cert and DNS plumbing are shared). ALB-fronting HEC is supported guidance (sticky sessions are set for useACK senders; Firehose supports ALB since 2024-01 and needs exactly the CA-signed cert the ALB provides; NLB is NOT supported for Firehose). Senders must be within sok\_web\_external\_allowed\_cidrs. | `bool` | `false` | no |
| <a name="input_sok_indexer_replicas"></a> [sok\_indexer\_replicas](#input\_sok\_indexer\_replicas) | IndexerCluster peers (single-site shape). The operator floors this at replication\_factor and docs state a minimum of 3. | `number` | `3` | no |
| <a name="input_sok_namespace"></a> [sok\_namespace](#input\_sok\_namespace) | Namespace for the Splunk Operator AND all Splunk CRs. Must be one namespace: a namespace-scoped operator only watches its own namespace (WATCH\_NAMESPACE). | `string` | `"splunk"` | no |
| <a name="input_sok_network_policies_enabled"></a> [sok\_network\_policies\_enabled](#input\_sok\_network\_policies\_enabled) | Enforce the splunk-namespace egress NetworkPolicy (SEC-5: no path from SOK pods to VPC-internal Splunk ports). Needs the vpc-cni network-policy agent (eks layer). Escape hatch: false. | `bool` | `true` | no |
| <a name="input_sok_operator_chart_version"></a> [sok\_operator\_chart\_version](#input\_sok\_operator\_chart\_version) | splunk/splunk-operator Helm chart version. CRDs are vendored separately in eks/files/ (removed from the chart in 3.0.0), bump BOTH together. | `string` | `"3.1.0"` | no |
| <a name="input_sok_pod_resources"></a> [sok\_pod\_resources](#input\_sok\_pod\_resources) | Per-pod CPU/memory requests+limits for the Splunk CRs. null = the dev Burstable default (requests << limits, everything on one node). Prod sets requests==limits for Guaranteed QoS (NFR-1), e.g. { requests = { cpu = "2", memory = "8Gi" }, limits = { cpu = "2", memory = "8Gi" } }. | <pre>object({<br/>    requests = object({ cpu = string, memory = string })<br/>    limits   = object({ cpu = string, memory = string })<br/>  })</pre> | `null` | no |
| <a name="input_sok_secret_admin_password_id"></a> [sok\_secret\_admin\_password\_id](#input\_sok\_secret\_admin\_password\_id) | Secrets Manager id of the Splunk admin password for the SOK global secret. dev: /dev/splunk/password (env-scoped, SEC-1). | `string` | `"/monitoring/splunk/password"` | no |
| <a name="input_sok_secret_hec_token_id"></a> [sok\_secret\_hec\_token\_id](#input\_sok\_secret\_hec\_token\_id) | Secrets Manager id of the persistent HEC token (OPS-14). CREATED and seeded by the account layer (which is not part of the nightly teardown), then read here so the token survives every rebuild instead of regenerating. Matches the /<env>/splunk/hec\_token naming convention the account layer writes. | `string` | `"/prod/splunk/hec_token"` | no |
| <a name="input_sok_secret_license_id"></a> [sok\_secret\_license\_id](#input\_sok\_secret\_license\_id) | Secrets Manager id of the enterprise licence blob. dev: /dev/splunk/license. | `string` | `"/monitoring/splunk/license"` | no |
| <a name="input_sok_secret_pass4symmkey_id"></a> [sok\_secret\_pass4symmkey\_id](#input\_sok\_secret\_pass4symmkey\_id) | Secrets Manager id of the cluster/SHC symmetric key. dev: /dev/splunk/pass4SymmKey (env-scoped, SEC-1). | `string` | `"/splunk/pass4SymmKey"` | no |
| <a name="input_sok_splunk_image"></a> [sok\_splunk\_image](#input\_sok\_splunk\_image) | Splunk Enterprise container image for all CRs (x86-64 only). Digest-pinned (SEC-6/DEP-8): the tag documents the version, the digest is what deploys, a mutated tag can't ride into the nightly rebuild. Captured from the validated 10.4.0 deploy; bump tag+digest together. | `string` | `"docker.io/splunk/splunk:10.4.0@sha256:5fef7b0d2c83f6e8b3fe3cda5885e2a01e3a6eb99d8502e6333aaa64e7021f62"` | no |
| <a name="input_sok_var_storage"></a> [sok\_var\_storage](#input\_sok\_var\_storage) | Per-pod /opt/splunk/var PVC size (holds the SmartStore cache). The operator NEVER resizes PVCs, size generously. | `string` | `"50Gi"` | no |
| <a name="input_sok_var_storage_by_role"></a> [sok\_var\_storage\_by\_role](#input\_sok\_var\_storage\_by\_role) | Per-role override of sok\_var\_storage (NFR-6), only indexers need the big SmartStore-cache volume; LM/MC/CM idle at a fraction. Keys: cm, idxc, sh, shc, lm, mc; unset roles use the global. | `map(string)` | `{}` | no |
| <a name="input_sok_web_external_allowed_cidrs"></a> [sok\_web\_external\_allowed\_cidrs](#input\_sok\_web\_external\_allowed\_cidrs) | Inbound allow-list on the external Splunk Web ALB. Empty = fall back to trusted\_cidrs. Set ["0.0.0.0/0"] to make it fully public, NB the SOK admin password is the estate's shared /monitoring/splunk/password (finding SEC-1), so keep this as narrow as the audience allows. | `list(string)` | `[]` | no |
| <a name="input_sok_web_external_certificate_arn"></a> [sok\_web\_external\_certificate\_arn](#input\_sok\_web\_external\_certificate\_arn) | ACM cert ARN for the ALB HTTPS listener. Empty = discover the most-recent ISSUED *.<sok\_web\_external\_zone\_name> cert. | `string` | `""` | no |
| <a name="input_sok_web_external_components"></a> [sok\_web\_external\_components](#input\_sok\_web\_external\_components) | Which Splunk UIs the external ALB fronts (host-based routing on ONE ALB). Keys: sh (search tier, Standalone or SHC by shape), cm, lm, mc, deployer (SHC shapes only). Indexers are never exposable (splunkweb disabled on peers). sh uses sok\_web\_external\_hostname; every other component gets <first-label>-<component>.<zone>, still covered by the *.<zone> cert. | `list(string)` | <pre>[<br/>  "sh"<br/>]</pre> | no |
| <a name="input_sok_web_external_enabled"></a> [sok\_web\_external\_enabled](#input\_sok\_web\_external\_enabled) | Expose Splunk Web (the SOK Standalone search head) on an internet-facing ALB Ingress. OFF by default, the normal access path is `kubectl port-forward`. When true, also set sok\_web\_external\_hostname + sok\_web\_external\_zone\_name. | `bool` | `false` | no |
| <a name="input_sok_web_external_hostname"></a> [sok\_web\_external\_hostname](#input\_sok\_web\_external\_hostname) | FQDN for the external Splunk Web ALB, e.g. sok-dev.splunk.livehybrid.com. MUST be covered by the ACM cert (a *.<zone> wildcard covers exactly one label). A CNAME to the ALB is created in sok\_web\_external\_zone\_name. | `string` | `""` | no |
| <a name="input_sok_web_external_zone_name"></a> [sok\_web\_external\_zone\_name](#input\_sok\_web\_external\_zone\_name) | Route53 public hosted zone that owns sok\_web\_external\_hostname (no trailing dot), e.g. splunk.livehybrid.com. Used for the CNAME record and, if sok\_web\_external\_certificate\_arn is empty, to discover the *.<zone> ACM cert. | `string` | `""` | no |
| <a name="input_state_bucket"></a> [state\_bucket](#input\_state\_bucket) | S3 bucket holding the terraform state for this workspace. | `any` | n/a | yes |
| <a name="input_trusted_cidrs"></a> [trusted\_cidrs](#input\_trusted\_cidrs) | n/a | `list(string)` | <pre>[<br/>  "0.0.0.0/0"<br/>]</pre> | no |
| <a name="input_vpc_flow_log_s3_arn"></a> [vpc\_flow\_log\_s3\_arn](#input\_vpc\_flow\_log\_s3\_arn) | Optional pre-existing S3 bucket ARN for VPC flow logs. Leave empty to skip flow-log export. | `string` | `""` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_gha_terraform_boundary_policy_arn"></a> [gha\_terraform\_boundary\_policy\_arn](#output\_gha\_terraform\_boundary\_policy\_arn) | n/a |
| <a name="output_gha_terraform_role_arn"></a> [gha\_terraform\_role\_arn](#output\_gha\_terraform\_role\_arn) | n/a |
| <a name="output_github_actions_role_arn"></a> [github\_actions\_role\_arn](#output\_github\_actions\_role\_arn) | ARN of the GitHubActionsTerraform CI role (assumed via OIDC by the SOK workflows). |
<!-- END_TF_DOCS -->
