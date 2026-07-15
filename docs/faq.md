# Frequently asked questions

Questions that come up running or demoing the SOK estate, with grounded answers.
For the design rationale see the [overview](kubernetes-sok-overview.md) and the
[operations runbook](kubernetes-sok-runbook.md).

## The Splunk Operator itself

### What does the Splunk Operator for Kubernetes actually do? The pods look like Splunk in a container.

The pods **are** the `splunk/splunk` container, correct. The operator is the layer
that turns a one-line declared intent into a correct, self-healing Splunk
topology and then keeps it that way. It is a Kubernetes controller (a reconcile
loop) that watches the Splunk Custom Resources (`Standalone`, `ClusterManager`,
`IndexerCluster`, `SearchHeadCluster`, `LicenseManager`, `MonitoringConsole`)
and, for each, does the work you would otherwise do by hand:

- Renders each CR into the underlying Kubernetes objects: StatefulSets, Services,
  ConfigMaps, Secrets, PVCs.
- Forms and maintains the cluster: points indexers at the cluster manager, search
  heads at the manager, sets the replication and search factors, multisite, the
  shared `pass4SymmKey` and the admin credentials, so you never run `splunk edit
  cluster-config` or bootstrap a captain by hand.
- Runs the App Framework: pulls apps from S3 and installs them by scope (a
  cluster-manager bundle to the indexers, a deployer bundle to the search-head
  cluster, local for a standalone or the monitoring console).
- Owns lifecycle: a version bump becomes an orchestrated rolling upgrade (with
  maintenance mode), a replica change becomes a graceful add or decommission, a
  dead pod is recreated by the StatefulSet and re-joined, and termination runs
  `splunk offline` so a peer leaves cleanly.
- Manages the secrets, the probes and the storage.

So the value is not the container, it is the continuous reconciliation: you
declare "a 3-indexer multisite cluster with a search-head cluster on SmartStore"
and the operator builds it, heals it and upgrades it. Without it you would script
all of that yourself.

### Is there a UI or a CLI for the operator, or do I only push changes through Terraform?

There is no operator UI and no dedicated operator CLI. The operator is driven
**declaratively**: you create or edit the Custom Resources (ordinary Kubernetes
objects) and it reconciles them. You can edit those CRs three ways:

- **Terraform** (our path): the `sok` layer defines the CRs, and `make sok-apply`
  applies them with a restart-risk gate.
- **kubectl** directly: `kubectl -n splunk get/edit clustermanager,indexercluster,...`.
  This is also how you inspect state, `kubectl get indexercluster -o yaml` shows
  `.status`.
- Any Kubernetes GitOps tool (Argo, Flux) if you ever wanted it.

Terraform is our chosen single source of truth, not a requirement of the
operator. Separately, each Splunk pod still serves its own Splunk Web on 8000
(reach it with a port-forward or the opt-in ALB), and `kubectl` is your
pod-level CLI. What you never do is "call the operator": you change desired
state and it converges.

### How does a change actually reach the pods?

Two distinct paths, and it matters which one a change uses:

| Change | Path | Command |
|---|---|---|
| Topology, replicas, resources, refs, SmartStore, probes | Terraform CR edit, operator reconciles | `make sok-apply` |
| Splunk config in an app (indexes, props, saved searches, dashboards, lookups) | App Framework: git to S3 to operator | `make sok-deploy-apps scope=...` |

`make sok-apply` never delivers an app, and `make sok-deploy-apps` never changes
the topology. See [CR vs app](#config-custom-resource-vs-app) below.

## Day-2 operations

### What happens when I add an indexer?

You raise `sok_indexer_replicas` (or the per-site count), run `make sok-apply`,
and the operator scales the IndexerCluster StatefulSet up. The new indexer pod
starts, registers with the cluster manager as a peer, and the manager rebalances
buckets to meet the replication and search factors. The monitoring console picks
it up as a new search peer.

If the new indexer does **not** come up, the usual cause (and the one you hit) is
**no node headroom**: the new pod needs a node with enough free CPU and memory to
satisfy its requests, and on a single small dev node there was none, so the pod
sat `Pending`. `kubectl -n splunk get pods` shows `Pending`, and `kubectl describe
pod <name>` shows `FailedScheduling ... Insufficient cpu/memory`. Adding a node
(or lowering the pod resource requests) fixes it, which is what you saw.

Note `replicas` is **per site** in a multisite cluster, so `sok_indexer_replicas
= 2` across two sites is four indexer pods.

### I saw `scale_splunk_indexer = 3` in the dev tfvars. What was that?

An **EC2 leftover**: the desired count of the old EC2 indexer auto-scaling group,
nothing to do with SOK. It has been removed from the tfvars in this refactor. The
SOK indexer count is `sok_indexer_replicas`, and the cluster's redundancy is
`replication_factor` / `search_factor`. If the numbers did not line up during the
demo, stale EC2 knobs like this are why.

### If I scale indexers down, say 3 to 2, does one just disappear?

No, the operator does not blind-delete a peer. On a replica decrease it
**gracefully decommissions** the peer being removed: it runs `splunk offline` so
the cluster manager re-replicates that peer's buckets onto the remaining peers to
preserve the replication and search factors, and only then removes the pod. This
matches the manual guidance (decommission one peer at a time, wait for the
cluster to rebalance before the next). Practical notes:

- Reduce by one at a time.
- Decommissioning is not instant: bucket fixup takes as long as it takes to move
  the data.
- Confirm RF/SF are met afterwards with `make sok-health`.

It is decommission-based, not a cluster-wide maintenance-mode freeze (maintenance
mode is what the operator uses for rolling restarts and upgrades, to suppress
bucket fixup, not for scale-down).

### The sok-apply script looks complicated. Does it apply each node type in order, and why?

It is simpler than it looks. `make sok-apply` does **one** `terraform plan` of the
whole `sok` layer, scans that plan for changes to the Splunk CRs, and if the
cluster is live it prints exactly which CRs the operator will restart and what
that means (SHC is rolling, indexers are rolling, the cluster manager and the
other singletons are a brief blip), then it applies the **saved** plan you just
reviewed. Its job is the **outage alert plus a reviewed apply**, not a
per-node-type loop.

Two separate things provide ordering:

- Within that single apply, Terraform's own dependency graph orders resource
  creation (the cluster manager before the indexers, secrets before the CRs, and
  so on, via `depends_on` in `crs.tf`).
- Optional **staging** across CRs is available with `target=`, for example roll
  the SHC first and the cluster manager last, running `make sok-health` between.
  That is a manual choice for controlling blast radius, not something the script
  does on its own.

So the iteration you saw in the output is the plan scan listing each CR that will
change, and the ordering is Terraform's graph plus the optional staged rollout.

To be clear, it **does** perform the apply, it is not only a checker: the plan and
the confirmation are the safety wrapper around a real `terraform apply` of the
`sok` layer. And it only covers **Terraform-managed** things (the CRs and their
topology). App or built-in-app changes (like the MC lookup sharing above) go
through the App Framework or a runtime REST call, never through `sok-apply`.

### If I push a new app to the search heads, does it restart them all at once, or roll?

Rolling, for a search-head cluster. The App Framework lands the app on the
deployer and the deployer runs `apply shcluster-bundle`, which triggers a
**rolling restart of the SHC members** (one at a time, so the captaincy and the
KV store stay available). It is not a simultaneous restart. For the dev standalone
search head there is only one pod, so it is a single restart. Whether a given app
forces any restart at all depends on the app: a bundle push that changes served
config does.

## Config: Custom Resource vs app

### What can I set on the Custom Resource, and what has to go in an app?

Rule of thumb: **the CR is the platform and topology, the app is the Splunk
config.**

- **On the CR** (the CRD spec): replicas, replication and search factor,
  multisite, the CM/LM/MC references, the SmartStore volume, storage sizes, pod
  resources, the App Framework `appRepo`, `defaults` / `defaultsUrl`, `extraEnv`,
  affinity and tolerations, probe overrides, the service template.
- **In an app** (delivered by the App Framework): indexes, props and transforms,
  saved searches, dashboards, inputs, macros, lookups, anything that is normally
  a `.conf`.

### How do I create a new index, in an app or through SOK?

In an **app**, not the CR. A new index is `indexes.conf`, which belongs in an app
delivered to the **cluster manager** via the `idx-apps/` prefix (cluster scope);
the manager then pushes it in the cluster bundle so every peer gets it and the
buckets replicate. Our SmartStore overlay index config already rides this path
(`configmaps.tf`). You can inline `indexes.conf` through the CR `defaults` for a
quick one-off, but for a clustered index the app-on-the-manager route is the
correct, scalable one. Do not add a cluster index directly on a peer, it will not
replicate.

### Where is the full list of fields I can put on a Custom Resource?

The CRD is the reference:

- `kubectl explain indexercluster.spec` (or `clustermanager.spec`, and so on)
  prints every field inline.
- The vendored CRD (`terraform/layers/sok/files/splunk-operator-crds.yaml`) and
  the [Splunk Operator Custom Resource Guide](https://splunk.github.io/splunk-operator/)
  document them in full.
- Our `crs.tf` is the worked example of the subset this estate uses, and `make
  terraform-docs` documents the `sok`-layer variables (the knobs we expose over
  the CRs).

## Monitoring console

### The MC saw the new indexer, but the SplunkAdmins search that auto-updates the MC config did not apply. Why?

The SplunkAdmins search rebuilds the monitoring console's distributed-search
config when peers change, and it does `| lookup dmc_assets ...` several times.
`dmc_assets` is owned by the built-in `splunk_monitoring_console` app and the
search runs in the **SplunkAdmins** app context, so the intuitive theory is that
`dmc_assets` is not shared globally and the `| lookup` cannot resolve it.

**Tested on the dev cluster (2026-07-15): that theory does not hold on this
build.** `dmc_assets`, both the lookup definition and its `assets.csv` table
file, is already **global** out of the box, `| lookup dmc_assets` resolves fine
from the SplunkAdmins context, and the MC-apply search runs to completion with no
error messages. So lookup sharing is not the gap here. If the search failed
during a demo, the likelier causes are that the MC apps were not deployed yet at
that moment (the `| curl` command comes from `TA-webtools`, so the search errors
if that add-on is absent), or the new peers had not finished registering.

If you ever do hit a build where `dmc_assets` genuinely is app-scoped, the fix is
to make it global (`sharing=global` on `data/transforms/lookups/dmc_assets` and
its table file). Because `splunk_monitoring_console` is a default app baked into
the image (its ACLs reset every rebuild, and the App Framework delivers whole
apps, not overlays of a built-in app), deliver that either as a **separate-named
setup app** that sets the ACL by REST on a schedule, or by **baking a `local.meta`
into a custom image**. Do **not** push a same-named `splunk_monitoring_console`
package to overlay it: the App Framework can replace the whole app directory,
wiping the built-in MC app. Either way it is an app / runtime change, not a
Terraform CR change, so it goes via the App Framework or REST, never `make
sok-apply`.

## Data and lifecycle

### The dev cluster is destroyed every night. Where does the data go?

Indexed data lives in **SmartStore on S3** (the `account` layer's SmartStore
bucket), which is persistent and never part of the nightly teardown, so warm and
cold buckets survive. The KV store (SHC dashboard state, lookups) is not covered
by SmartStore, so it is backed up separately to the KV-backup bucket (`make
sok-kvstore-backup`) and restored on demand. The apps come from the persistent
apps bucket. So a nightly destroy and recreate loses only the ephemeral compute,
not the data.

### How do I reach Splunk Web and get the admin password?

`make kubeconfig env=dev`, then a port-forward (services are ClusterIP) or the
opt-in per-component ALB (`make sok-urls`). The admin user is `admin` (not the
EC2 estate's `splunkadmin`); `make sok-password env=dev` prints the password.

### How do I upgrade the Splunk version?

Bump the operator's Splunk image on the CRs (via the `sok` layer) and
`make sok-apply`. The operator performs an orchestrated rolling upgrade with
maintenance mode, one tier at a time, rather than restarting everything at once.
Stage it with `target=` if you want to control the order.
