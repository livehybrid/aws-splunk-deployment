# LiveHybrid Splunk Cluster (AWS)

**IMPORTANT** - This is a public version of a long-standing repo which began back in
March 2019 when setting out to build a Terraform-based AWS deployment of Splunk on EC2.  
Since then it has been used for numerous environment with different customers and use-cases 
and is now shared for others to make use of, but is done so with No Guarantee, No Warranty 
and on the basis that there is no automatic free support provided.  
Recently the repo has been expanded to include SOK support, some of the documentation relates
to AI-based peer reviews and analysis. Disclaimer: Some AI-written code exists within the repo 
however this has been done with close peer-reviewing. 
  
Please use the Issues tab to raise any issues you encounter or contact me directly for paid-support 
or consulting using the contact form at [https://www.livehybrid.com/contact](https://www.livehybrid.com/contact)  

# Introduction 
This is a sample Terraform implementation for deploying Splunk in AWS 
either as EC2 instances or leveraging EKS and running Splunk Operator for Kuberenetes.
Choice of EC2 or SOK easily configurable and allows environments to be managed easily 
and quickly.   
Features all core Splunk deployment instance types (Indexer Clustering, Cluster Manager, Search Head Clustering, 
License Manager, Deployment, Monitoring Console, Heavy Forwarder ingest tier, with **SmartStore on S3** and full TLS
verification against an internal PKI (on EC2 - SOK requires further dev work)

## 📚 Documentation

Full docs live in [`docs/`](docs/index.md) as an MkDocs Material site,
`make docs-serve` for a local preview; published to GitHub Pages via
`.github/workflows/docs.yml` once the repo is public.

Two deployment styles run the same topology against the same SmartStore data,
picked per workspace by `deployment_model`: **EC2** (Terraform + Packer) and
 **Kubernetes (SOK)** (Splunk Operator on EKS); These are mutually exclusive per 
 workspace/environment.

**Shared / overview**

- [Overview](docs/index.md) — the docs home and where-to-go index
- [LLD workbook](docs/LLD-workbook.md) — customer decisions, RACI, assumptions, risk register (EC2 C3 reference build)

**EC2 (Terraform + Packer)**

- [Architecture](docs/architecture.md) — topology diagrams, multisite layout, ports
- [Getting started](docs/getting-started.md) — AMI build, apply order, first deploy from zero
- [Configuration reference](docs/configuration.md) — every tfvars knob (`multisite`, `data_volume_filesystem`, `ssl_verify_server_cert`, …)
- [Operations runbook](docs/operations.md) — make targets, start/stop lifecycle
- [Apps & deployment](docs/apps.md) — apps repo layout, per-tier deploys, fail-closed sync
- [Security & TLS](docs/security.md) — internal PKI, cert-issuer Lambda, secrets inventory
- [CI / GitHub Actions](docs/ci.md) — start/stop/checks/deploy/Packer/Infracost/docs workflows
- [Troubleshooting](docs/troubleshooting.md) — the hard-won list

**Kubernetes (SOK)**

- [Overview](docs/kubernetes-sok-overview.md) — the working model: operator, CRs, layers, lifecycle, external access
- [Operations runbook](docs/kubernetes-sok-runbook.md) — day-2 tasks, restart blast radius, DR posture, EKS version cliff
- [Design study](docs/kubernetes-sok.md) — migrating the M3 build to the Splunk Operator on EKS, EC2-vs-SOK toggle design
- [Implementation plan](docs/kubernetes-sok-plan.md) — phase-by-phase build (K1–K5), layer deltas, status
- [Monitoring app plan](docs/kubernetes-sok-monitoring-app-plan.md) — planned in-Splunk SOK health app (OPS-4)
- [Apps repo handoff](docs/apps-repo-handoff.md) — the git→S3→App Framework contract + queued app work
- [Community lessons](docs/kubernetes-sok-community-lessons.md) — Gareth Anderson (SplunkTrust) digest vs this build
- [Handoff, lessons remainder](docs/handoff-sok-lessons-remainder.md) — executable spec for the remaining Anderson items (task #55)
- [SOK review](docs/reviews/index.md) — the four-lens (security, ops, deployment, non-functional) SOK review

## Quickstart

```sh
make splunk-versions                  # look up current Splunk 10.x + build
make packer-build-splunk env=prod     # build AMI (or use the GitHub Action)
# paste AMI ID into terraform/layers/_shared/vars/prod.tfvars
make terraform env=prod               # walks account → iam → cluster
make smoke env=prod && make health env=prod   # verify
```

First deploy in a fresh account has one-time prerequisites (state bucket,
hosted zone, operator secrets) — see
[Getting started](docs/getting-started.md).

Day-to-day: `make` with no arguments prints every target. Cluster power
controls (start / nightly auto-stop / checks) run as GitHub Actions — see
[CI](docs/ci.md).

## Versions

Terraform `>= 1.10` · AWS provider `~> 5.80` · Packer `>= 1.11` (HCL2) ·
Amazon Linux 2023 · Splunk Enterprise 10.x (pinned per `<env>.tfvars`)
