#!/usr/bin/env bash
# One-time bootstrap of the GitHub Actions OIDC trust for the Packer build
# workflow.
#
# What this creates in your AWS account:
#   1. An OIDC identity provider for token.actions.githubusercontent.com
#      (idempotent — skipped if it already exists).
#   2. An IAM role `GitHubActionsPacker` that GitHub Actions can assume from
#      the configured repo, attached to a managed policy with the EC2
#      permissions Packer's amazon-ebs builder needs.
#
# Once this finishes, copy the printed role ARN into the GitHub repo's
# Settings → Secrets and variables → Actions → Variables → New variable:
#   Name:  AWS_PACKER_ROLE_ARN
#   Value: arn:aws:iam::<account>:role/GitHubActionsPacker
#
# Usage:
#   ./scripts/setup-github-oidc.sh <github-org/repo>
# e.g.
#   ./scripts/setup-github-oidc.sh livehybrid/aws-splunk-cluster
set -euo pipefail

REPO="${1:?'usage: setup-github-oidc.sh <github-org/repo>'}"
ROLE_NAME="GitHubActionsPacker"
POLICY_NAME="GitHubActionsPacker"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
PROVIDER_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"

echo "==> account=${ACCOUNT_ID} repo=${REPO}"

# 1. OIDC identity provider (one per account/URL; safe to attempt twice).
if ! aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$PROVIDER_ARN" >/dev/null 2>&1; then
  echo "==> creating OIDC provider"
  aws iam create-open-id-connect-provider \
    --url     https://token.actions.githubusercontent.com \
    --client-id-list  sts.amazonaws.com \
    --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
else
  echo "==> OIDC provider already present"
fi

# 2. Role trust policy — scoped to the repo (any branch).
TRUST=$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect":    "Allow",
    "Principal": { "Federated": "${PROVIDER_ARN}" },
    "Action":    "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
      },
      "StringLike": {
        "token.actions.githubusercontent.com:sub": "repo:${REPO}:*"
      }
    }
  }]
}
JSON
)

if ! aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "==> creating role ${ROLE_NAME}"
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "$TRUST" \
    --description "Assumed by GitHub Actions to build Splunk AMIs via Packer"
else
  echo "==> role ${ROLE_NAME} exists; updating trust policy"
  aws iam update-assume-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-document "$TRUST"
fi

# 3. Permission policy — based on HashiCorp's documented minimum for the
#    amazon-ebs builder. Scope kept account-wide because Packer creates
#    short-lived resources tagged with timestamps.
POLICY=$(cat <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "PackerAmazonEBS",
      "Effect": "Allow",
      "Action": [
        "ec2:AttachVolume",
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:CopyImage",
        "ec2:CreateImage",
        "ec2:CreateKeypair",
        "ec2:CreateSecurityGroup",
        "ec2:CreateSnapshot",
        "ec2:CreateTags",
        "ec2:CreateVolume",
        "ec2:DeleteKeyPair",
        "ec2:DeleteSecurityGroup",
        "ec2:DeleteSnapshot",
        "ec2:DeleteVolume",
        "ec2:DeregisterImage",
        "ec2:DescribeImageAttribute",
        "ec2:DescribeImages",
        "ec2:DescribeInstances",
        "ec2:DescribeInstanceStatus",
        "ec2:DescribeRegions",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeSnapshots",
        "ec2:DescribeSubnets",
        "ec2:DescribeTags",
        "ec2:DescribeVolumes",
        "ec2:DescribeVpcs",
        "ec2:DetachVolume",
        "ec2:GetPasswordData",
        "ec2:ModifyImageAttribute",
        "ec2:ModifyInstanceAttribute",
        "ec2:ModifySnapshotAttribute",
        "ec2:RegisterImage",
        "ec2:RunInstances",
        "ec2:StopInstances",
        "ec2:TerminateInstances"
      ],
      "Resource": "*"
    },
    {
      "Sid": "PackerEbsEncryption",
      "Effect": "Allow",
      "Action": [
        "kms:CreateGrant",
        "kms:Decrypt",
        "kms:DescribeKey",
        "kms:Encrypt",
        "kms:GenerateDataKey*",
        "kms:ReEncrypt*"
      ],
      "Resource": "*"
    }
  ]
}
JSON
)

echo "==> putting inline policy ${POLICY_NAME}"
aws iam put-role-policy \
  --role-name   "$ROLE_NAME" \
  --policy-name "$POLICY_NAME" \
  --policy-document "$POLICY"

echo
echo "==> done"
echo "Role ARN: arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
echo
echo "Next: in GitHub → Settings → Secrets and variables → Actions → Variables, add"
echo "      Name=AWS_PACKER_ROLE_ARN   Value=arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
