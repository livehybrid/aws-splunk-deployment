# Operations (summary)

This is the operations entry point. Everything operational goes through `make`
and `kubectl` (via `make kubeconfig`), no SSH keys. `make` with no target
prints the annotated target list. The full day-2 runbook (restart blast
radius, DR posture, KV backup/restore, the EKS version cliff) lives in the
[SOK operations runbook](kubernetes-sok-runbook.md).

## Deploy / verify

| Command | What it does |
| --- | --- |
| `make terraform env=dev` | apply the layers in order (`account` → `iam` → `eks` → `sok`) |
| `make kubeconfig env=dev` | point kubectl at the `splunk-sok-<env>` EKS cluster |
| `make sok-status env=dev` | CR phases (CM / IndexerCluster / Standalone / LM / MC) + pods |
| `make sok-health env=dev` | **Splunk-side** checks via `kubectl exec`: RF/SF, SHC captaincy + KV store, licence, MC. Auth as `admin`, password read *inside* the pod; asserts `entry` (the silent-401 trap) |

## Interact with the cluster

| Command | What it does |
| --- | --- |
| `make kexec env=dev role=cm\|indexer\|sh\|lm\|mc` | shell into a Splunk pod (`sh` resolves Standalone or SHC) |
| `make sok-deploy-apps env=dev [scope=all]` | package the apps repo → S3 (App Framework); the operator polls (600s) and installs, PodCopying to the pods |
| `make sok-kvstore-backup env=prod` | back up the SHC KV store to the KV-backup bucket (also a 6h CronJob) |
| `make sok-kvstore-restore env=prod [archive=<name>]` | restore the KV store, targets the KV-store captain |
| `make sok-rf-remediate env=dev` | fix the SmartStore cold-boot RF/SF stall; a no-op once at RF+SF |

## Lifecycle / cost control

| Command | What it does |
| --- | --- |
| **SOK START** (GitHub Action or `make terraform`) | apply `eks` then `sok` (~20–25 min); the cluster cold-boots and self-assembles |
| **SOK STOP** (Action, nightly 21:30 UTC for dev) | the only route to ~$0 overnight: a full **destroy** of `sok` then `eks`, an EKS control plane bills ~$0.10/hr just for existing. The persistent data in the `account` layer (SmartStore + apps + KV-backup S3/KMS) survives |

⚠ **Stop is a full destroy/recreate, not a park.** Order matters: destroy sok
(namespace deletion cascades the PVCs while the CSI driver still exists, so
`reclaimPolicy: Delete` reclaims the EBS volumes), wait for zero cluster-tagged
volumes, then destroy eks. KV-store content is disposable in dev; the source of
truth is SmartStore (S3) + git + Secrets Manager.

!!! warning "Nightly auto-stop (dev)"
    The stop workflow runs on a **21:30 UTC cron** for dev as a cost guard.
    Anything not in the persistent `account` buckets does not survive the
    night. Prod, once cut over, runs always-on (it can't park without dropping
    live ingest).

## Cold-boot behaviour

A cold start against a populated SmartStore bucket re-discovers all previous
buckets from S3 ("legacy" buckets whose origin GUIDs belong to terminated
pods). Expect a few minutes of RF/SF fixup after the peers join. If fixups
stall on the known legacy-bucket signature, `make sok-rf-remediate env=<env>`
detects it and triggers one rolling restart, the SOK CHECKS workflow can call
it between retries.

## Alerting

Lifecycle failures (START / STOP / CHECKS) post to Slack when the repo secret
`SLACK_WEBHOOK_URL` is set, a **failed nightly STOP is the one that matters
most** (the cluster keeps billing overnight). In-cluster alerting (the 6-hourly
KV backup CronJob, operator reconcile errors, pod crash-loops) is an open
decision tracked as OPS-4, see the [runbook](kubernetes-sok-runbook.md).
