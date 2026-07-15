# LiveHybrid Splunk Cluster (AWS)

Terraform + Packer deployment of a Splunk Enterprise **multisite indexer
cluster** (Cluster Manager + 2×2 indexers across two AZs + 3-member Search
Head Cluster + Deployer + License Manager + Monitoring Console + Heavy
Forwarder ingest tier) on AWS, with **SmartStore on S3** and full
**TLS verification** against an internal PKI.

## Workspace sizing

| Workspace | Indexers | Sites | Site RF / SF | SHC | Notes |
| --- | --- | --- | --- | --- | --- |
| `prod` | 4 (2 per AZ) | site1 = eu-west-2a, site2 = eu-west-2b | origin:2,total:3 / origin:1,total:2 | 3 members across 3 AZs (site0) | Currently cost-minimum (t3a.medium, on-demand) — see `prod.tfvars` for the full-size values to restore for real workload |
| `dev`  | 1 (eu-west-2a) | single-site | RF 1 / SF 1 | standalone SH (`enable_shc=false`) | |

A whole-AZ loss in prod leaves at least one copy of every bucket in the
surviving site (`site_replication_factor = origin:2,total:3`).

## Two deployment styles

This estate ships **two** ways to run the same Splunk topology against the
same SmartStore data, picked per workspace by `deployment_model` in the tfvars:

- **EC2 (Terraform + Packer)** — the original build: role ASGs + a baked AMI,
  bootstrap templates, the `cluster` layer. `deployment_model = "ec2"` (prod
  today). The EC2 pages below cover it.
- **Kubernetes (SOK)** — the Splunk Operator for Kubernetes on EKS, declared as
  Custom Resources. `deployment_model = "sok"` (dev today). The Kubernetes (SOK)
  pages below cover it.

The two are **mutually exclusive per workspace** — one SmartStore bucket, one
live cluster manager (guards in both paths enforce it).

## Shared / overview

- **[LLD workbook](LLD-workbook.md)** — customer decision questionnaire, RACI, assumptions and risk register (EC2 C3 reference build)

## EC2 (Terraform + Packer)

- **[Architecture](architecture.md)** — topology diagrams, multisite layout, ports
- **[Getting started](getting-started.md)** — AMI build, apply order, first deploy from zero
- **[Configuration reference](configuration.md)** — every tfvars knob (`multisite`, `data_volume_filesystem`, `ssl_verify_server_cert`, …)
- **[Operations runbook](operations.md)** — make targets, start/stop lifecycle, app deploys
- **[Apps & deployment](apps.md)** — apps repo layout, per-tier deploys, fail-closed sync
- **[Security & TLS](security.md)** — internal PKI, cert-issuer Lambda, secrets inventory
- **[CI / GitHub Actions](ci.md)** — start/stop/checks/deploy/Packer/Infracost/docs workflows
- **[Troubleshooting](troubleshooting.md)** — the hard-won list

## Kubernetes (SOK)

- **[Overview](kubernetes-sok-overview.md)** — the working model: operator, CRs, layers, lifecycle, external access
- **[Operations runbook](kubernetes-sok-runbook.md)** — day-2 tasks, restart blast radius, DR posture, EKS version cliff
- **[Design study](kubernetes-sok.md)** — the research and rationale behind the SOK path, EC2-vs-SOK toggle design
- **[Implementation plan](kubernetes-sok-plan.md)** — phase-by-phase build (K1–K5), layer deltas, status
- **[Apps repo handoff](apps-repo-handoff.md)** — the git→S3→App Framework contract + queued app work
- **[Community lessons](kubernetes-sok-community-lessons.md)** — Gareth Anderson (SplunkTrust) digest vs this build
- **[Review](reviews/index.md)** — the four-lens (security, ops, deployment, non-functional) SOK review

## Versions

- Terraform `>= 1.10`, AWS provider `~> 5.80`
- Packer `>= 1.11` (HCL2), Amazon Linux 2023
- Splunk Enterprise 10.x — version+build pinned per `<env>.tfvars`; list at
  <https://raw.githubusercontent.com/livehybrid/downloadSplunk/refs/heads/main/version.list>
