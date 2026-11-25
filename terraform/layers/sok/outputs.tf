###############################################################################
# Layer outputs.
#
# Restored from the outputs.tf that f8dafa3 ("reduce down to sok only") removed
# wholesale: README.md still documents all four, so the code and the generated
# docs had drifted apart. Brought up to date with two things that changed
# since: the named SH/SHC maps (crs.tf) replaced the enable_shc boolean, and
# data.terraform_remote_state.eks is gone (terraform.tf), so the kubeconfig
# command is built from data.aws_eks_cluster.this instead.
###############################################################################

output "namespace" {
  description = "Kubernetes namespace holding the operator and every Splunk CR."
  value       = local.namespace
}

output "smartstore_bucket" {
  description = "S3 bucket backing SmartStore for this environment."
  value       = data.aws_s3_bucket.smartstore.bucket
}

# Every exposed component gets its own Route53 CNAME onto the shared ALB
# (<prefix>-<component>.<zone>, web-ingress.tf), so hand them back as
# ready-to-click HTTPS URLs rather than leaving operators to reassemble the
# name by hand. Keyed off the RECORDS, not local.web_component_hosts, so the
# map can only ever list names that were really created, and so terraform never
# renders a URL before Route53 has it. fqdn is trimmed defensively: Route53
# names are stored with a trailing dot and a URL must not carry one.
output "web_external_urls" {
  description = "Public UI URLs per exposed component when sok_web_external_enabled=true (else {}); includes hec when sok_hec_external_enabled."
  value = merge(
    { for c, r in aws_route53_record.web : c => "https://${trimsuffix(r.fqdn, ".")}" },
    local.hec_external_enabled ? { hec = "https://${trimsuffix(one(aws_route53_record.hec[*].fqdn), ".")}" } : {}
  )
}

# App Framework layout. Which prefix an app belongs in decides which tier
# installs it and whether it lands via the cluster bundle, the deployer or a
# straight pod copy, and getting it wrong is silent: the operator installs the
# app somewhere harmless and the tier you meant never sees it. Rendered from
# local.app_sources (appframework.tf), which the SH/SHC entries share with the
# CR appRepos, so this cannot claim a prefix the operator is not polling.
output "app_locations" {
  description = "Where to upload Splunk apps in the apps bucket, keyed by appSource name (the name that appears in operator logs and CR status). Drop one .tgz or .spl per app directly under the prefix, no nesting. The operator re-polls every 600s."
  value = { for name, s in local.app_sources : name => {
    s3_uri          = "s3://${data.aws_s3_bucket.apps.bucket}/${s.location}"
    scope           = s.scope
    installs_to     = s.installs_to
    custom_resource = s.custom_resource
  } }
}

output "hints" {
  description = "Copy-paste next steps: kubeconfig, CR status, per-instance port-forwards and the external URLs."
  value = <<-EOT
    aws eks update-kubeconfig --name ${data.aws_eks_cluster.this.name} --region ${var.region}${var.profile != "" ? " --profile ${var.profile}" : ""}
    kubectl get clustermanager,indexercluster,searchheadcluster,standalone,licensemanager,monitoringconsole -n ${local.namespace}

    # Splunk Web via port-forward (admin / password from ${var.sok_secret_admin_password_id})
    ${join("\n", concat(
  [for k in keys(local.shc_map) : "kubectl port-forward -n ${local.namespace} svc/splunk-shc-${k}-search-head-service 8000:8000   # SHC ${k}"],
  [for k in keys(local.sh_map) : "kubectl port-forward -n ${local.namespace} svc/splunk-sh-${k}-standalone-service 8000:8000   # standalone SH ${k}"],
  ))}

    # Splunk Web via the external ALB
    ${var.sok_web_external_enabled ? join("\n", [
  for c, r in aws_route53_record.web : "open https://${trimsuffix(r.fqdn, ".")}   # ${c}"
]) : "# external web disabled (set sok_web_external_enabled=true to expose an ALB)"}
  EOT
}