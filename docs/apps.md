# Apps & deployment

## Apps repo

`apps_git_repo` (currently `github.com/livehybrid/splunk-apps.git`, private)
is cloned at boot by the manager and deployer. Expected layout:

| Path in repo | Synced to | Consumed by |
| --- | --- | --- |
| `manager-apps/` | CM `etc/manager-apps/` | `make push-cluster-bundle` → indexers |
| `deployment-apps/` (+ serverclass config) | CM `etc/deployment-apps/` | UF/HF deployment clients |
| `apps/` | CM `etc/apps/` (merge-only) | CM-local apps |
| `shcluster/apps/` | deployer `etc/shcluster/apps/` | `make push-shc-bundle` → SHC |

Secrets in app configs use `#splunksecret:/path/in/secrets-manager#`
placeholders, substituted on-instance during sync.

## Deploying

```sh
make deploy-apps env=prod scope=idx   # CM cluster bundle → indexers
make deploy-apps env=prod scope=shc   # deployer bundle → SHC
make deploy-apps env=prod scope=ds    # deployment-server reload (UF/HF clients)
make deploy-apps env=prod scope=cm    # CM's own etc/apps (restarts CM)
make deploy-apps env=prod             # all = idx + shc + ds
```

The same scopes are available from the **deploy-apps GitHub Action**
(workflow_dispatch → pick env + scope).

## Sync safety (fail-closed)

**Design note — why the mgmt port is NOT gated at boot:** the old edge
deployment set `[httpServer] disableDefaultPort = true` so forwarders
couldn't phone home before config was applied (avoiding the "downloaded
empty serverclasses → deleted apps" incident). In a C3 the same port 8089
carries indexer↔CM clustering, deployer pushes and the CLI, so gating it
breaks the cluster (it did — see [Troubleshooting](troubleshooting.md)). The
protection now lives in the sync instead:

- git clone retries 3×;
- a repo directory that is missing **or empty** is never rsync'd over live
  apps (`--delete` from an empty source is exactly the old incident);
- `etc/apps` is merge-only (never `--delete`) so Splunk built-ins survive;
- the CM's `_cluster` bundle dir is excluded from deletion.

A failed/empty clone leaves the DS unconfigured — phone-home then changes
nothing on clients, which is the safe state.

## SOK app pipeline (deployment_model=sok)

!!! note "SOK app delivery"
    This section is the EC2-page summary of the SOK pipeline. The full
    contract and queued app work live in the
    [apps repo handoff](apps-repo-handoff.md); the mechanism is described in
    the [SOK overview](kubernetes-sok-overview.md).

Under SOK, apps flow **git → S3 → App Framework** instead of being cloned
on-instance. `scripts/package-apps.sh <env> [scope]` (or `make sok-deploy-apps`)
clones the apps repo, tars each app with a **stable filename** (change detection
is Etag-by-filename — a rename breaks upgrade tracking) and uploads to per-scope
prefixes in the persistent apps bucket:

| Repo dir | S3 prefix | CR / scope |
| --- | --- | --- |
| `apps/` | `cm-apps/`, `sh-apps/` | ClusterManager / Standalone (scope local) |
| `manager-apps/` | `idx-apps/` | ClusterManager (scope cluster → indexers via bundle) |
| `shcluster/apps/` | `shc-apps/` | SearchHeadCluster (scope local, prod) |
| `deployment-apps/` | — | skipped: SOK has no DS CRD (edge stays EC2) |

Only the **operator** pod reads the bucket (App Framework Download phase, via
IRSA — no static keys); Splunk pods receive apps via PodCopy. The CRs poll every
600 s (`appsRepoPollIntervalSeconds`; unset/0 = polling disabled). Force a poll
via the `splunk-splunk-manual-app-update` ConfigMap in the namespace.

⚠ Deleting an archive does **not** uninstall the app (retire by shipping a final
version with `state = disabled`). ⚠ These apps carry EC2-specific
`#splunksecret#` / `master_uri` bits that App Framework does **not** substitute —
parameterise before relying on their runtime behaviour under SOK.

## Longer-term shape (decision D4 in the LLD)

The single apps repo is the bootstrap-era shape. The intended end state is
per-app repos (or a GitLab group) with a manifest + packaged-artifact channel
(S3) and cross-repo dispatch triggering `deploy-apps` on merge — recorded as
an open customer decision in the [LLD workbook](LLD-workbook.md).
