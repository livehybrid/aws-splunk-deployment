#!/usr/bin/env bash
# Mirror the NVIDIA device plugin image into this account's private ECR.
#
#   AWS_REGION=eu-west-2 ./scripts/mirror-device-plugin.sh [tag]
#
# nvcr.io is not a supported ECR pull-through upstream, so in a VPC without
# internet egress the one image the AI tier cannot get from the cache has to be
# copied in once. Run it from any machine with internet and ECR push rights; the
# copy is registry-to-registry (no local docker daemon needed).
#
# Then set, and apply the ai layer:
#   ai_nvidia_device_plugin_image = "<printed reference>"
#
# Needs: the AWS CLI and crane (github.com/google/go-containerregistry).
# The tag should match the chart's appVersion for ai_nvidia_device_plugin_chart_version.
set -euo pipefail

: "${AWS_REGION:?set AWS_REGION}"
TAG="${1:-v0.20.1}"
REPO="nvidia/k8s-device-plugin"
SRC="nvcr.io/nvidia/k8s-device-plugin:${TAG}"

command -v crane >/dev/null || { echo "crane not found: https://github.com/google/go-containerregistry/tree/main/cmd/crane" >&2; exit 1; }

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
REGISTRY="${ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com"

aws ecr describe-repositories --region "$AWS_REGION" --repository-names "$REPO" >/dev/null 2>&1 \
  || aws ecr create-repository --region "$AWS_REGION" --repository-name "$REPO" \
       --image-scanning-configuration scanOnPush=true >/dev/null

aws ecr get-login-password --region "$AWS_REGION" | crane auth login "$REGISTRY" -u AWS --password-stdin

# Copies the full multi-arch index, so the tag resolves on any node architecture.
crane copy "$SRC" "${REGISTRY}/${REPO}:${TAG}"

echo "ai_nvidia_device_plugin_image = \"${REGISTRY}/${REPO}:${TAG}\""
