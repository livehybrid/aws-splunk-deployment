# LiveHybrid Splunk Cluster (AWS)

Terraform deployment of a Splunk Enterprise **multisite indexer cluster**
(Cluster Manager + 2×2 indexers across two AZs + 3-member Search Head Cluster
+ Deployer + License Manager + Monitoring Console) on AWS via the **Splunk
Operator for Kubernetes (SOK)** on EKS, with **SmartStore on S3**.

## Workspace sizing

| Workspace | Indexers | Sites | Site RF / SF | SHC | Notes |
| --- | --- | --- | --- | --- | --- |
| `prod` | 4 (2 per AZ) | site1 = eu-west-2a, site2 = eu-west-2b | origin:2,total:3 / origin:1,total:2 | 3 members across 3 AZs (site0) | Currently cost-minimum (staged t3 shape), see `prod.tfvars` for the full-size values to restore for real workload |
| `dev`  | 1 (eu-west-2a) | single-site | RF 1 / SF 1 | standalone SH (`enable_shc=false`) | |

A whole-AZ loss in prod leaves at least one copy of every bucket in the
surviving site (`site_replication_factor = origin:2,total:3`).

## Deployment model

This estate runs Splunk on **Kubernetes (SOK)**, the Splunk Operator for
Kubernetes on EKS, declared as Custom Resources. Because the index data lives
in S3 (SmartStore), the compute is disposable: dev tears itself down every
night and rebuilds from scratch, and the persistent data outlives every
teardown.

The bring-up layers are: bootstrap (state bucket + GitHub OIDC provider,
out-of-band) → `account` → `iam` (CI role only) → `eks` → `sok`. The
persistent SmartStore bucket + KMS, the apps bucket, the KV-backup bucket and
the HEC-token secret all live in the `account` layer.

## Shared / overview

- **[LLD workbook](LLD-workbook.md)**, customer decision questionnaire, RACI, assumptions and risk register (C3 reference build)

## Documentation

- **[Overview](kubernetes-sok-overview.md)**, the working model: operator, CRs, layers, lifecycle, external access, architecture
- **[Getting started](getting-started.md)**, apply order, first deploy from zero
- **[Configuration reference](configuration.md)**, every tfvars knob (`multisite`, `data_volume_filesystem`, `eks_*`, `sok_*`, …)
- **[Operations (summary)](operations.md)**, the make/workflow entry points, pointing at the runbook
- **[Operations runbook](kubernetes-sok-runbook.md)**, day-2 tasks, restart blast radius, DR posture, EKS version cliff
- **[Apps & deployment](apps.md)**, the git→S3→App Framework contract + queued app work
- **[Security & TLS](security.md)**, SOK security posture, secrets inventory, S2S/8089/SmartStore TLS
- **[CI / GitHub Actions](ci.md)**, start/stop/checks/deploy/Infracost/docs workflows
- **[Design study](kubernetes-sok.md)**, the research and rationale behind the SOK path
- **[Implementation plan](kubernetes-sok-plan.md)**, phase-by-phase build (K1–K5), layer deltas, status
- **[Community lessons](kubernetes-sok-community-lessons.md)**, Gareth Anderson (SplunkTrust) digest vs this build
- **[Review](reviews/index.md)**, the four-lens (security, ops, deployment, non-functional) SOK review

## Versions

- Terraform `>= 1.10`, AWS provider `~> 5.80` (the `eks` layer pins its own `~> 6.x`)
- SOK 3.1.0, Splunk Enterprise 10.4 (image pinned per `<env>.tfvars`), EKS 1.34
