###############################################################################
# SEC-2: permissions boundary for the GitHubActionsTerraform CI role.
#
# The CI role carries PowerUserAccess (+ explicit iam: grants) so it can run
# terraform across the whole estate. PowerUser has no iam:* but our passrole
# policy grants CreateRole/AttachRolePolicy/PassRole on splunk-*/eks-node roles,
# which is a privilege-escalation surface. Rather than hand-craft a least-priv
# policy now (high risk of breaking terraform), we CAP the role with a deny-list
# permissions boundary: Allow "*" so normal terraform is unaffected, then Deny
# only the escalation / guardrail-tampering vectors below.
#
# Migrating to a least-privilege managed policy is a FOLLOW-UP; the boundary is
# the interim, non-breaking control.
#
# NB the boundary is attached to the role by whoever applies THIS iam layer
# locally (an operator with iam:PutRolePermissionsBoundary), not by the CI role
# mid-run. Terraform sets permissions_boundary on the role resource below.
###############################################################################

data "aws_iam_policy_document" "gha_terraform_boundary" {
  # Baseline: allow everything. The boundary only ever SUBTRACTS via the Deny
  # statements that follow, so it does not restrict normal terraform operations.
  statement {
    sid       = "AllowAllByDefault"
    effect    = "Allow"
    actions   = ["*"]
    resources = ["*"]
  }

  # No new human or long-lived credentials (cut the classic escalation paths).
  statement {
    sid    = "DenyNewLongLivedCredentials"
    effect = "Deny"
    actions = [
      "iam:CreateUser",
      "iam:CreateAccessKey",
      "iam:CreateLoginProfile",
      "iam:UpdateLoginProfile",
    ]
    resources = ["*"]
  }

  # Never attach AdministratorAccess or PowerUserAccess to any role or user.
  # iam:PolicyARN is the request condition key for the *managed* policy being
  # attached (valid for Attach{Role,User}Policy).
  statement {
    sid    = "DenyAttachAdminManagedPolicy"
    effect = "Deny"
    actions = [
      "iam:AttachRolePolicy",
      "iam:AttachUserPolicy",
    ]
    resources = ["*"]
    condition {
      test     = "ArnEquals"
      variable = "iam:PolicyARN"
      values = [
        "arn:aws:iam::aws:policy/AdministratorAccess",
        "arn:aws:iam::aws:policy/PowerUserAccess",
      ]
    }
  }

  # Protect the boundary itself: the CI role must not be able to remove or swap
  # its own boundary, nor edit/delete the boundary policy document. Without this
  # the whole control is one API call away from being undone.
  statement {
    sid    = "DenyEditingOwnBoundary"
    effect = "Deny"
    actions = [
      "iam:DeleteRolePermissionsBoundary",
      "iam:DeleteUserPermissionsBoundary",
    ]
    resources = ["*"]
  }
  statement {
    sid    = "DenyReplacingOwnBoundary"
    effect = "Deny"
    actions = [
      "iam:PutRolePermissionsBoundary",
      "iam:PutUserPermissionsBoundary",
    ]
    # Only the CI role's own boundary is protected here; estate roles created by
    # terraform may legitimately have (or gain) their own boundaries later.
    # ARN built from the known role name (not the resource attribute) to avoid a
    # dependency cycle: the role's permissions_boundary points back at this policy.
    resources = ["arn:aws:iam::${local.account_id}:role/GitHubActionsTerraform"]
  }
  statement {
    sid    = "DenyMutatingBoundaryPolicy"
    effect = "Deny"
    actions = [
      "iam:DeletePolicy",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:SetDefaultPolicyVersion",
    ]
    # ARN built from the known policy name (not the resource attribute) to avoid
    # a self-referential cycle: this document IS this policy's body.
    resources = ["arn:aws:iam::${local.account_id}:policy/GitHubActionsTerraformBoundary"]
  }

  # Deny creating a role WITHOUT a permissions boundary, so the CI role cannot
  # spin up a fresh unbounded role and escalate through it. iam:PermissionsBoundary
  # is the request key holding the boundary ARN; Null=true means "key absent",
  # i.e. no boundary supplied.
  #
  # NotResource EXEMPTS the estate's own role name-shapes, which terraform
  # legitimately creates without a boundary today (EKS cluster/IRSA roles
  # splunk-sok-*, the events-to-HEC role splunk-*, and the EKS node-group roles
  # general-*-eks-node-group-*). Any OTHER new role must carry a boundary.
  statement {
    sid    = "DenyCreateRoleWithoutBoundary"
    effect = "Deny"
    actions = [
      "iam:CreateRole",
    ]
    not_resources = [
      "arn:aws:iam::${local.account_id}:role/splunk-*",
      "arn:aws:iam::${local.account_id}:role/general-*-eks-node-group-*",
    ]
    condition {
      test     = "Null"
      variable = "iam:PermissionsBoundary"
      values   = ["true"]
    }
  }

  # No account/organisation level changes.
  statement {
    sid    = "DenyAccountAndOrgControl"
    effect = "Deny"
    actions = [
      "organizations:*",
      "account:*",
    ]
    resources = ["*"]
  }

  # Do not let CI disable the audit / detective guardrails.
  statement {
    sid    = "DenyDisablingGuardrails"
    effect = "Deny"
    actions = [
      "cloudtrail:StopLogging",
      "cloudtrail:DeleteTrail",
      "cloudtrail:UpdateTrail",
      "cloudtrail:PutEventSelectors",
      "config:DeleteConfigurationRecorder",
      "config:DeleteDeliveryChannel",
      "config:StopConfigurationRecorder",
      "config:DeleteConfigRule",
      "guardduty:DeleteDetector",
      "guardduty:DisassociateFromMasterAccount",
      "guardduty:UpdateDetector",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "gha_terraform_boundary" {
  name        = "GitHubActionsTerraformBoundary"
  description = "SEC-2 permissions boundary capping the CI role (deny-list; allow-all baseline)."
  policy      = data.aws_iam_policy_document.gha_terraform_boundary.json
}

output "gha_terraform_boundary_policy_arn" {
  value = aws_iam_policy.gha_terraform_boundary.arn
}
