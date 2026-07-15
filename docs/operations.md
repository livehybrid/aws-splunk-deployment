# Operations runbook

This is the **EC2** operations runbook (`deployment_model = "ec2"`). Everything
operational goes through `make` and SSM — no SSH keys, no inbound management
ports. `make` with no target prints the annotated target list.

!!! note "Running SOK instead?"
    The [SOK (Kubernetes) path](#sok-kubernetes-path) section below is a short
    parallel of the EC2 targets. The full day-2 runbook for
    `deployment_model = "sok"` (restart blast radius, DR posture, KV
    backup/restore, the EKS version cliff) lives in the
    [SOK operations runbook](kubernetes-sok-runbook.md).

## Deploy / verify

| Command | What it does |
| --- | --- |
| `make terraform env=prod` | apply all three layers in order |
| `make smoke env=prod` | AWS-side checks: ASG capacity, instance state, TG health, SmartStore bucket, DNS |
| `make health env=prod` | **Splunk-side** checks via SSM: indexer cluster RF/SF/searchable + peer count, SHC captaincy (elected + dynamic + service-ready), KV store (ready, exactly one captain, no failed members), licence validity, MC search peers |
| `make status env=prod` | instance + ASG inventory table |

A full deployment verification is `make smoke` (AWS converged) then
`make health` (Splunk converged).

## Interact with the cluster

| Command | What it does |
| --- | --- |
| `make ssm env=prod role=manager` | interactive shell on a role (SSM session) |
| `make splunk-cmd env=prod role=manager cmd="show cluster-status"` | run any splunk CLI command as admin (password resolved from Secrets Manager *on the instance* — never transits your shell) |
| `make password env=prod` | print where/how to retrieve the admin password |
| `make push-cluster-bundle env=prod` | validate + `apply cluster-bundle` on the CM (distributes `manager-apps/` to all indexers), then shows bundle status |
| `make push-shc-bundle env=prod` | `apply shcluster-bundle` from the Deployer targeting a live SHC member (pushes `shcluster/apps/`) |
| `make rolling-restart env=prod role=indexer` | CM-coordinated rolling restart of indexer peers |
| `make rolling-restart env=prod role=searchhead` | SHC rolling restart via the captain |
| `make deploy-apps env=prod [scope=...]` | per-tier app deploy: `idx` (cluster bundle), `shc` (SHC bundle), `ds` (deploy-server reload for license/UF clients), `cm` (CM's own apps, restarts it), `all` = idx+shc+ds |
| `make rotate-admin env=prod` | rotate the splunkadmin password fleet-wide — manager generates + stores the new secret, every node re-auths via Secrets Manager version stages (password never transits your shell) |
| `make mc-register env=prod` | force a Monitoring Console peer-reconciliation run (normally automatic via systemd timer) |

## Lifecycle / cost control

| Command | What it does |
| --- | --- |
| `make recycle env=prod [role=indexer]` | terminate instances; ASGs relaunch from the latest launch template — the fast path after AMI or bootstrap changes. SmartStore data survives; local cache is lost |
| **Stop** (GitHub Action or local overlay apply) | zeroes every `enable_splunk_*`, destroying ASGs/LTs/EBS/LBs while keeping S3, KMS, Secrets, Route53, IAM, ACM. Residual ≈$8/mo |
| **Start** (GitHub Action or `make terraform`) | re-applies the workspace tfvars; the cluster cold-boots and self-assembles |

Local overlay apply (what the stop Action runs):

```sh
cd terraform/layers/cluster
terraform apply -var-file=vars/prod.tfvars -var-file=vars/prod-shutdown.tfvars
```

What keeps costing while shut down: S3 buckets (pennies while empty), 2 KMS
keys (~$2/mo), Secrets Manager secrets (~$2.40/mo), Route53 zones (~$1/mo),
AMI snapshot (~$1/mo). No NAT gateway exists; the only VPC endpoint is the
free S3 gateway.

!!! warning "Nightly auto-stop"
    The stop workflow also runs on a **22:30 UTC cron** as a cost guard.
    Comment out the `schedule:` block in `splunk-stop.yml` when working late.

## SOK (Kubernetes) path

When `deployment_model = "sok"` the estate runs on the eks + sok layers
(operator + CRs) instead of the EC2 cluster. Ops targets parallel the EC2 ones
(the full SOK day-2 runbook is [here](kubernetes-sok-runbook.md)):

| Command | What it does |
| --- | --- |
| `make kubeconfig env=dev` | point kubectl at the `splunk-sok-<env>` EKS cluster |
| `make sok-status env=dev` | CR phases (CM/IndexerCluster/Standalone/LM/MC) + pods |
| `make kexec env=dev role=cm\|indexer\|sh\|lm\|mc` | shell into a Splunk pod |
| `make sok-health env=dev` | deep Splunk checks via `kubectl exec` — RF/SF, KV store, licence (auth as `admin`, password read inside the pod; asserts `entry`, the silent-401 trap) |
| `make sok-deploy-apps env=dev [scope=all]` | package the apps repo → S3 (App Framework); the operator polls (600s) and installs, PodCopying to the pods |
| **SOK START** (GitHub Action) | apply eks then sok (~20–25 min) |
| **SOK STOP** (Action, nightly 21:30 UTC) | the only route to ~$0 overnight: destroy sok then eks — an EKS control plane bills ~$0.10/hr just for existing. The persistent `sok-foundation` (SmartStore + apps S3/KMS) survives |

⚠ **Stop is a full destroy/recreate, not a park.** Order matters: destroy sok
(namespace deletion cascades the PVCs while the CSI driver still exists, so
`reclaimPolicy: Delete` reclaims the EBS volumes), wait for zero cluster-tagged
volumes, then destroy eks. KV-store content is disposable in dev; the source of
truth is SmartStore (S3) + git + Secrets Manager.

## Cold-boot behaviour

A cold start against a populated SmartStore bucket re-discovers all previous
buckets from S3 ("legacy" buckets whose origin GUIDs belong to terminated
instances). Expect a few minutes of RF/SF fixup after the peers join.
If fixups stall with "Missing enough suitable candidates" /
"No possible srcs for replication", `scripts/rf-remediate.sh <env>` detects
the signature and triggers one rolling restart — the chained checks workflow
already calls it automatically between retries.

## Alerting

The `splunk-ops-alert` SNS topic fans out to Slack
(`/monitoring/alerts/slack_webhook`) and Telegram
(`/monitoring/alerts/telegram`). ASG lifecycle changes and spot interruption
warnings are also forwarded to Splunk's HEC via an EventBridge API
destination (`aws_events_hec.tf`) — searchable under the `aws-events` token's
index.
