#!/usr/bin/env bash
# Stage Splunk AI tier model weights into the artifacts bucket.
#
#   AI_BUCKET=$(terraform -chdir=terraform/layers/ai output -raw ai_bucket) \
#   AWS_REGION=eu-west-2 HF_TOKEN=hf_... ./scripts/ai-stage-models.sh [l40s|h100]
#
# One-off per bucket: the bucket lives in the persistent account layer, so the
# weights survive the nightly rebuild and this does not need re-running.
# Already-staged models are skipped, so a re-run after a flaky download is safe.
#
# Uses Splunk's own download/upload scripts from the operator repository at the
# release this deployment pins, so the model set always matches the operator.
#
# Needs: git, the AWS CLI with write access to the bucket, >= 250 GB free disk
# and >= 16 GB RAM (Splunk's stated minimum). Gated Hugging Face models (Gemma)
# need HF_TOKEN from an account that has accepted each model's licence.
set -euo pipefail

: "${AI_BUCKET:?set AI_BUCKET (terraform output ai_bucket of the ai layer)}"
ACCELERATOR="${1:-l40s}"
case "$ACCELERATOR" in l40s|h100) ;; *) echo "accelerator must be l40s or h100" >&2; exit 1 ;; esac

OPERATOR_VERSION="${OPERATOR_VERSION:-1.0.0}"
WORK="${WORK:-$(mktemp -d)}"
echo "working in $WORK (needs >= 250 GB free)"

git clone --quiet --depth 1 --branch "v${OPERATOR_VERSION}" \
  https://github.com/splunk/splunk-ai-operator.git "$WORK/operator"

cd "$WORK/operator/tools/artifacts_download_upload_scripts"
[ -x ./download_from_huggingface.sh ] || { echo "download script not found at v${OPERATOR_VERSION}; check the release layout" >&2; exit 1; }

./download_from_huggingface.sh --accelerator "$ACCELERATOR"

# The AIPlatform reads s3://<bucket>/artifacts and Ray expects the weights at
# artifacts/model_artifacts/<model>/ (terraform/layers/ai/main.tf).
# S3_REGION is passed explicitly: the upstream script defaults to us-east-2.
S3_BUCKET="$AI_BUCKET" \
S3_REGION="${AWS_REGION:?set AWS_REGION to the bucket region}" \
S3_PREFIX="artifacts/model_artifacts" \
SKIP_IF_STAGED=1 \
  ./upload_to_s3.sh

echo "staged $ACCELERATOR weights to s3://$AI_BUCKET/artifacts/model_artifacts"
