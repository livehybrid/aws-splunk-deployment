output "ai_bucket" {
  description = "Artifacts bucket the AIPlatform reads model weights from. Stage weights with scripts/ai-stage-models.sh before the first Ray worker starts."
  value       = local.enabled ? local.ai_bucket_name : ""
}

output "splunk_issuer" {
  description = "JWT issuer the AI tier trusts. Set the search head's issuer_uri to exactly this string (docs/ai-tier.md, step 3)."
  value       = local.enabled ? local.splunk_issuer : ""
}

output "ai_role_arn" {
  description = "IRSA role assumed by the AI tier service accounts."
  value       = local.enabled ? aws_iam_role.ai[0].arn : ""
}

# The operator names the SAIA and SLIM Services after the AIPlatform and
# feature; discover them rather than hard-code a name that may change.
output "next_steps" {
  description = "Commands for the post-apply steps in docs/ai-tier.md."
  value = local.enabled ? join("\n", [
    "kubectl get aiplatform ai -n ${local.namespace}",
    "kubectl get svc -n ${local.namespace} | grep -E 'saia|slim'",
    "SAIA (Splunk AI Assistant -> Configuration): http://<saia-service>.${local.namespace}.svc.cluster.local:8080",
    "SLIM (AI Toolkit -> Connections -> Splunk AI tier): http://<slim-service>.${local.namespace}.svc.cluster.local:<port>/tenant/slim-api/v1alpha1",
  ]) : ""
}
