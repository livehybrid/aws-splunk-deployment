###############################################################################
# OIDC role for the splunk-start / splunk-stop GitHub Actions workflows.
# Trusts the same GitHub OIDC provider as the (hand-created) packer role.
# PowerUser for the cluster-layer resources + explicit PassRole for the
# splunk instance profiles (PowerUserAccess excludes iam:*).
###############################################################################

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "gha_terraform_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    # SEC-2: trust ONLY the default branch, `repo:...:*` let ANY ref (feature
    # branches, PR merge refs) assume a PowerUser-grade role. The scheduled and
    # dispatched workflows all run from master once merged; a dispatch from any
    # other branch is now (deliberately) denied. Add specific refs here if a
    # non-master dispatch is ever genuinely needed.
    # ⚠ Takes effect on the next iam-layer apply, do that AFTER the SOK branch
    #   merges, or master-less dispatches keep working/failing confusingly.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:livehybrid/aws-splunk-cluster:ref:refs/heads/master"]
    }
  }
}

resource "aws_iam_role" "gha_terraform" {
  name               = "GitHubActionsTerraform"
  assume_role_policy = data.aws_iam_policy_document.gha_terraform_trust.json

  # SEC-2: cap privilege escalation with a deny-list permissions boundary (see
  # gha_terraform_boundary.tf). PowerUserAccess stays attached for now (the
  # boundary caps it); migrating to a least-privilege managed policy is a
  # follow-up. Applied by the operator running the iam layer locally, not by the
  # CI role mid-run.
  permissions_boundary = aws_iam_policy.gha_terraform_boundary.arn
}

# PowerUserAccess is deliberately retained: it lets the CI role run terraform
# across the estate. The permissions boundary above caps what it can actually
# do. FOLLOW-UP (SEC-2): replace with a least-privilege managed policy once the
# exact terraform action set is characterised.
resource "aws_iam_role_policy_attachment" "gha_terraform_poweruser" {
  role       = aws_iam_role.gha_terraform.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

data "aws_iam_policy_document" "gha_terraform_passrole" {
  statement {
    actions = ["iam:PassRole"]
    resources = [
      "arn:aws:iam::${local.account_id}:role/Splunk*",
      "arn:aws:iam::${local.account_id}:role/splunk-*",
      # eks-layer node-group roles are named after the node-group KEY, not the
      # estate prefix (module behaviour), passed to EKS on nodegroup create.
      "arn:aws:iam::${local.account_id}:role/general-*-eks-node-group-*",
    ]
  }

  # The eks layer (deployment_model=sok, CI-driven start/stop) creates and
  # destroys its own IAM: cluster role + ClusterEncryption policy + IRSA roles
  # (all splunk-sok-*), node-group roles (general-*-eks-node-group-*), and the
  # cluster OIDC provider. PowerUserAccess excludes iam:* entirely, so these are
  # granted explicitly and stay ENUMERATED BY NAME-SHAPE (SEC-2: no iam:* here).
  statement {
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:UpdateRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:TagRole", "iam:UntagRole", "iam:ListRoleTags",
      "iam:PutRolePolicy", "iam:GetRolePolicy", "iam:DeleteRolePolicy",
      "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
      "iam:AttachRolePolicy", "iam:DetachRolePolicy",
      "iam:ListInstanceProfilesForRole",
    ]
    resources = [
      "arn:aws:iam::${local.account_id}:role/splunk-sok-*",
      "arn:aws:iam::${local.account_id}:role/general-*-eks-node-group-*",
    ]
  }

  statement {
    actions = [
      "iam:CreatePolicy", "iam:DeletePolicy", "iam:GetPolicy",
      "iam:GetPolicyVersion", "iam:ListPolicyVersions",
      "iam:CreatePolicyVersion", "iam:DeletePolicyVersion",
      "iam:TagPolicy", "iam:UntagPolicy", "iam:ListPolicyTags",
      "iam:ListEntitiesForPolicy",
    ]
    resources = ["arn:aws:iam::${local.account_id}:policy/splunk-sok-*"]
  }

  statement {
    actions = [
      "iam:CreateOpenIDConnectProvider", "iam:DeleteOpenIDConnectProvider",
      "iam:GetOpenIDConnectProvider", "iam:TagOpenIDConnectProvider",
      "iam:UntagOpenIDConnectProvider",
    ]
    resources = ["arn:aws:iam::${local.account_id}:oidc-provider/*"]
  }

  # The cluster layer manages lower-case splunk-* roles (e.g. the
  # EventBridge->HEC delivery role), so the CI role must be able to CRUD them.
  statement {
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:UpdateRole",
      "iam:TagRole", "iam:UntagRole",
      "iam:PutRolePolicy", "iam:GetRolePolicy", "iam:DeleteRolePolicy",
      "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
      "iam:AttachRolePolicy", "iam:DetachRolePolicy",
      "iam:ListInstanceProfilesForRole",
    ]
    resources = ["arn:aws:iam::${local.account_id}:role/splunk-*"]
  }

  statement {
    actions   = ["iam:ListAccountAliases"]
    resources = ["*"]
  }
  statement {
    actions = [
      "iam:GetRole",
      "iam:GetInstanceProfile",
      "iam:ListInstanceProfilesForRole",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "gha_terraform_passrole" {
  name   = "passrole-splunk-profiles"
  role   = aws_iam_role.gha_terraform.id
  policy = data.aws_iam_policy_document.gha_terraform_passrole.json
}

output "gha_terraform_role_arn" {
  value = aws_iam_role.gha_terraform.arn
}
