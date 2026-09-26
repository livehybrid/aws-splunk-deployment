# Splunk AI tier on EKS

Optional, off by default (`ai_tier_enabled = false`). Deploys Splunk's
Kubernetes-native **AI tier** onto the same EKS cluster as SOK, connected to a SOK
standalone search head, so the **Splunk AI Assistant** and the **AI Toolkit's**
`ai` command run on self-hosted models instead of a cloud service.

Built against **Splunk AI Operator v1.0.0** (2026-08-27, the first GA release) and
**Splunk Operator 3.2.0**.

## What gets deployed

```
GPU nodes (eks_node_groups[*].gpu = true, AL2023 NVIDIA AMI)
  └── Ray GPU workers (KubeRay)          serve the LLMs
General nodes
  ├── Ray head, Weaviate (vector DB)
  ├── SAIA API v1/v2 + data loader       Splunk AI Assistant backend
  ├── SLIM service                       model endpoint for the AI Toolkit
  └── Splunk AI Operator, KubeRay        reconcile the AIPlatform
SOK standalone search head               issues the JWTs SAIA and SLIM trust
S3 (account layer)                       model weights, AI artifacts
```

| Layer | Adds when `ai_tier_enabled` |
| --- | --- |
| account | artifacts bucket `<prefix>-splunk-<env>-splunk-ai-<env>` (persistent) |
| eks | nothing automatically; you add a `gpu = true` node group |
| sok | cert-manager (shared with private-CA TLS) |
| **ai** (new) | NVIDIA device plugin, Splunk AI Operator, IRSA, `AIPlatform` |

Apply order `account → eks → sok → ai`; destroy `ai` first.

## Decisions worth knowing

- **The AI operator chart's bundled Splunk Operator and cert-manager are disabled.**
  The chart ships SOK 3.0.0 enabled by default; installing it as-is would run a
  second, older SOK controller against this cluster's 3.2.0. cert-manager comes
  from the sok layer instead.
- **Images are always pinned explicitly.** The chart's own defaults
  (`saia-api:1.1.0`, `slim-api:1.0.0`, stock Ray) are not the combination Splunk
  qualified. `ai_images` defaults to the qualified v1.0 set, all public on Docker
  Hub, pulled through the ECR cache when `use_ecr_pullthrough_cache` is on.
- **The AIPlatform runs in the SOK namespace.** Splunk's tested JWT contract uses
  the search head's *short* service name as the issuer
  (`https://splunk-sh-<name>-standalone-service:8089`), which only resolves from
  the same namespace.
- **S3 via IRSA**, no static keys. `ai_object_storage_secret` is a fallback only.
- **The artifacts bucket is SSE-S3 and has no `DenyUnencrypted` statement**:
  neither Ray nor the upstream upload scripts send the SSE header.
- **SAIA shares the Splunk Web ALB** (same ingress group), so no second load
  balancer.
- **The chart's OpenTelemetry subchart is disabled.** Its bundled
  `values.schema.json` is invalid against the JSON Schema metaschema, and
  Helm 3.19 refuses to install the chart because of it (3.17 accepts it).
  Nothing in the operator watches OpenTelemetry types, and the AIPlatform's
  OTel sidecar is off, so nothing is lost.
- **kube-prometheus-stack stays on** (`ai_monitoring_enabled`). The AIService
  controller watches `ServiceMonitor`, so the operator will not start without
  that CRD. Turn it off only where the cluster already runs the Prometheus
  Operator.

## Qualified versions

Splunk qualified exactly this combination for v1.0; anything else is untested:

| Component | Version |
| --- | --- |
| Splunk Enterprise | **10.2** |
| Splunk AI Assistant app (Splunkbase 7245) | 2.3.0 |
| Splunk AI Toolkit app (Splunkbase 2890) | ≥ 6.1.0 |
| AI tier / Splunk AI Operator | v1.0 |
| Kubernetes on EKS (per Splunk's EKS guide) | 1.31 to 1.34 |

⚠ This repo runs Splunk 10.4 by default. A `check` block warns on every plan when
`sok_splunk_image` is not 10.2; it does not block. Kubernetes 1.34 is inside both
the AI tier range (1.31 to 1.34) and SOK 3.2.0's (1.32 to 1.36).

## Cost

The GPU node group dominates. Splunk recommends `g6e.12xlarge` (4× L40S), about
**$7.77/hour** on-demand in Splunk's EKS guide, or roughly $5,600 a month if left
running. Smaller single-GPU options (`g5.2xlarge`, 1× A10G) exist for evaluation
but serve a smaller model set. This estate's nightly destroy applies here too.
Check GPU service quotas for your region before the first apply: they default low.

## Enabling it

```hcl
ai_tier_enabled      = true
ai_gpu_instance_type = "g6e.12xlarge"
ai_accelerator_type  = "L40S"
ai_search_head       = "default"          # a sok_standalone_search_heads key
ai_ingress_host      = "ai.example.com"   # users' browsers call SAIA directly

eks_node_groups = {
  # ...existing groups...
  gpu-a = {
    instance_type     = "g6e.12xlarge"
    gpu               = true              # NVIDIA AMI, GPU label and taint
    desired           = 1
    min               = 1
    max               = 1
    availability_zone = "eu-west-2a"
  }
}
```

Plan-time preconditions refuse to apply without a `gpu = true` group, with a GPU
instance type that doesn't match it, without the named standalone search head,
or on a Splunk Operator below 3.2.0.

## After apply

### 1. Stage the model weights (once per bucket)

More than 120 GB from Hugging Face; needs 250 GB free disk and 16 GB RAM on the
machine running it. Gated models (Gemma) need a Hugging Face token from an
account that has accepted each model's licence.

```bash
AI_BUCKET=$(terraform -chdir=terraform/layers/ai output -raw ai_bucket) \
AWS_REGION=eu-west-2 HF_TOKEN=hf_... \
./scripts/ai-stage-models.sh l40s
```

The bucket is in the persistent account layer, so this survives every rebuild.

### 2. Install the apps on the search head

Place the Splunkbase packages in the App Framework bucket under the search head's
prefix (`sh-<name>-apps/`), as for any other app: `Splunk_AI_Assistant_Cloud.tgz`
(AI Assistant 2.3.0) and, for the `ai` command, the AI Toolkit.

### 3. Point the search head's JWT issuer at itself

SAIA rejects tokens whose `iss` does not exactly match the issuer it trusts.
`terraform output splunk_issuer` gives the string. Deliver it in a small app
through App Framework, not `etc/system/local` (splunk-ansible deletes files it
manages there):

```ini
# <app>/local/authentication.conf
[oauth2_settings]
issuer_uri  = https://splunk-sh-default-standalone-service:8089
certFile    = $SPLUNK_HOME/etc/auth/server.pem
sslPassword = <server.pem passphrase>
```

If private-CA TLS is enabled (`sok_private_ca_enabled`), point `certFile` at the
operator-mounted certificate instead, so the issuer presents a certificate SAIA
can verify.

### 4. Connect the apps to the AI tier

```bash
terraform -chdir=terraform/layers/ai output -raw next_steps
```

- **Splunk AI Assistant → Configuration:** the in-cluster SAIA URL,
  `http://<saia-service>.<namespace>.svc.cluster.local:8080`.
- **AI Toolkit → Connections → Splunk AI tier:** the SLIM URL, including the
  `/tenant/slim-api/v1alpha1` suffix.

## Verify

1. `kubectl get aiplatform ai -n splunk` reaches Ready.
2. GPU nodes advertise GPUs:
   `kubectl get nodes -l nvidia.com/gpu.present=true -o jsonpath='{..allocatable.nvidia\.com/gpu}'`
3. Ray workers load models without `Invalid repository ID or local directory`
   (that error means the weights are missing or at the wrong prefix; see below).
4. A test prompt in the AI Assistant returns an answer.

## Open questions, to settle on the first run

These could not be confirmed from the documentation alone:

1. **Weight prefix.** Splunk's docs disagree: the EKS guide uses
   `path: s3://<bucket>/artifacts` with Ray reading
   `artifacts/model_artifacts/<model>`, while a troubleshooting note says
   `model_artifacts/<model>` at the bucket root. This layer follows the former. If
   Ray reports missing models, compare `aws s3 ls` against the path in the error.
2. **Whether Ray's S3 downloader honours IRSA.** If workers get access denied,
   set `ai_object_storage_secret` to a Secret with `s3_access_key` and
   `s3_secret_key`.
3. **SAIA's health path** for the ALB target group. Undocumented; if targets show
   unhealthy, confirm it on a pod and add the `healthcheck-path` annotation in
   `terraform/layers/ai/main.tf`.
4. **A search head cluster as the target.** Not qualified by Splunk for v1.0; the
   layer only accepts a standalone.
