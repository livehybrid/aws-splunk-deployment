output "github_actions_role_arn" {
  description = "ARN of the GitHubActionsTerraform CI role (assumed via OIDC by the SOK workflows)."
  value       = aws_iam_role.gha_terraform.arn
}
