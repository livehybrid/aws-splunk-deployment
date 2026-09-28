# LiveHybrid Splunk on AWS (SOK)

**IMPORTANT** - This is a public version of a long-standing private repo. It began
in March 2019 as a Terraform-based AWS deployment of Splunk on EC2, and has since
been used across many environments and customers. This public edition is the
**Splunk Operator for Kubernetes (SOK)** deployment: Splunk Enterprise on EKS with
**SmartStore on S3**. It is shared for others to use with No Guarantee, No Warranty
and no automatic free support. Some of the documentation relates to AI-based peer
reviews and analysis, and some AI-written code exists in the repo, all done with
close peer review.

Please use the Issues tab to raise anything you hit, or contact me directly for
paid support or consulting via the contact form at
[https://www.livehybrid.com/contact](https://www.livehybrid.com/contact)

# Introduction

A sample Terraform implementation for deploying Splunk on AWS using the **Splunk
Operator for Kubernetes** on EKS. It stands up the core Splunk topology (indexer
clustering, cluster manager, search head clustering, license manager, monitoring
console) with **SmartStore on S3**, driven declaratively through the operator's
Custom Resources.

The estate is designed for a nightly stop/start (a full destroy and rebuild), so a
dev environment costs almost nothing overnight. The persistent data (SmartStore,
the App Framework apps bucket, KV-store backups and the HEC token) lives in a
foundation layer that is never torn down, so a rebuild comes back with its data
intact.

TLS: SmartStore to S3/KMS is verified against the OS trust bundle. By default
splunkd (8089) uses self-signed certificates and S2S (9997) is plaintext; set
`sok_private_ca_enabled` to issue both from an existing AWS Private CA through
the operator's native certificate management
([TLS from AWS Private CA](docs/private-ca-tls.md)).

### Optional features

All off by default unless noted, each a variable in `terraform/layers/_shared/variables.tf`:

| Feature | Variable(s) |
| --- | --- |
| Multisite indexer clustering, one IndexerCluster per site pinned to its AZ (see `vars/overlays/dev-multisite.tfvars`) | `multisite`, `available_sites` |
| Dedicated, tainted node groups per Splunk role | `eks_node_groups[*].role`, `sok_indexer_node_role` |
| NVMe instance-store RAID-0 for the indexer SmartStore cache | `eks_node_groups[*].nvme_local_storage`, `sok_indexer_nvme_var_storage` |
| Per-role PVC sizing and Guaranteed-QoS pod resources | `sok_*_storage_by_role`, `sok_pod_resources` |
| Splunk Web and HEC behind an ALB | `sok_web_external_enabled`, `sok_hec_external_enabled` |
| TLS from AWS Private CA (8089 and S2S) | `sok_private_ca_enabled` |
| Private subnets with egress provided elsewhere (NAT, transit gateway, proxy) | `map_public_ip_on_launch`, `enable_internet_gateway` (both default `true`) |
| Private EKS endpoint reached through a tunnel | `k8s_proxy_url` (and `K8S_PROXY` for scripts) |
| Organisation tagging policy, forwarded to instances and volumes | `extra_default_tags` |
| Load generation with [Stoker](https://github.com/livehybrid/stoker) and search load with [Regulator](https://github.com/livehybrid/regulator) | `sok_enable_stoker`, `sok_enable_regulator` |

## 📚 Documentation

Full docs live in [`docs/`](docs/index.md) as an MkDocs Material site.
`make docs-serve` for a local preview; published to GitHub Pages via
`.github/workflows/docs.yml`.

The estate is four Terraform layers, applied in order: **account** (the persistent
foundation: VPC, endpoints, KMS, the SmartStore / apps / KV-backup buckets and the
HEC secret), **iam** (the GitHub Actions OIDC CI role), **eks** (the cluster, nodes,
storage) and **sok** (the operator, CRDs and the Splunk Custom Resources). Each
layer's inputs/outputs are documented in its own README via `make terraform-docs`.
An optional fifth layer, **ep**, runs Splunk Edge Processor instances on the
cluster against an existing control plane ([docs](docs/edge-processor.md)).

**Overview**

- [Overview](docs/index.md), the docs home and where-to-go index
- [Getting started](docs/getting-started.md), the apply order and first deploy from zero
- [FAQ](docs/faq.md), what the operator actually does, day-2 questions, CR vs app
- [LLD workbook](docs/LLD-workbook.md), decisions, assumptions, risk register

**Guide**

- [Configuration reference](docs/configuration.md), every tfvars knob (`multisite`, `data_volume_filesystem`, RF/SF, `enable_shc`, the `sok_*` / `eks_*` knobs)
- [Operations runbook](docs/operations.md), make targets and the start/stop lifecycle
- [Apps & deployment](docs/apps.md), the git to S3 to App Framework pipeline
- [Security & TLS](docs/security.md), SmartStore TLS, the SOK secrets, and the cert-management options (including AWS Private CA)
- [CI / GitHub Actions](docs/ci.md), the SOK start/stop/checks/deploy/docs workflows
- [Edge Processor](docs/edge-processor.md), the optional ep layer: Edge Processor instances on EKS behind NLBs

**Kubernetes (SOK)**

- [Overview](docs/kubernetes-sok-overview.md), the working model: operator, CRs, layers, lifecycle, external access
- [Operations runbook](docs/kubernetes-sok-runbook.md), day-2 tasks, restart blast radius, DR posture, EKS version cliff
- [Design study](docs/kubernetes-sok.md), the operator design (historical build record)
- [Implementation plan](docs/kubernetes-sok-plan.md), the phase-by-phase build (historical build record)
- [Community lessons](docs/kubernetes-sok-community-lessons.md), Gareth Anderson (SplunkTrust) digest vs this build
- [SOK review](docs/reviews/index.md), the four-lens (security, ops, deployment, non-functional) review

## Quickstart

```sh
# one-time bootstrap in a fresh account: the state bucket + the GitHub OIDC provider
make terraform env=dev                # applies account -> iam -> eks -> sok in order
make kubeconfig env=dev
make sok-status env=dev && make sok-health env=dev   # verify
```

Day to day the ephemeral eks + sok layers are brought up and torn down by GitHub
Actions (SOK START and the nightly SOK STOP), so dev is destroyed overnight and
rebuilt on demand while the account foundation persists. `make` with no arguments
prints every target. See [CI](docs/ci.md).

First deploy in a fresh account has one-time prerequisites (the state bucket, the
GitHub OIDC provider, and the admin / pass4SymmKey / licence secrets), see
[Getting started](docs/getting-started.md).

## Versions

Terraform `>= 1.11` · AWS provider `~> 5.80` · EKS `1.34` · Splunk Operator with
Splunk Enterprise 10.x (pinned per `<env>.tfvars`)
