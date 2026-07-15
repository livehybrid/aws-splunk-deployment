# Apps & deployment

## Apps repo

`apps_git_repo` (currently `github.com/livehybrid/splunk-apps.git`, private) is
the source of the Splunk apps. Under SOK the apps flow **git → S3 → App
Framework** rather than being cloned on-instance. Expected repo layout:

| Repo dir | S3 prefix | CR / scope |
| --- | --- | --- |
| `apps/` | `cm-apps/`, `sh-apps/` | ClusterManager / Standalone (scope local) |
| `manager-apps/` | `idx-apps/` | ClusterManager (scope cluster → indexers via bundle) |
| `shcluster/apps/` | `shc-apps/` | SearchHeadCluster (scope local, prod) |
| `deployment-apps/` | n/a | skipped: SOK has no Deployment Server CRD, so external UF/HF fleets are managed outside the operator |

Secrets in app configs use `#splunksecret:/path/in/secrets-manager#`
placeholders. ⚠ App Framework does **not** substitute these, parameterise any
app carrying `#splunksecret#` / `master_uri` bits before relying on its runtime
behaviour under SOK.

## Deploying

`scripts/package-apps.sh <env> [scope]` (or `make sok-deploy-apps`) clones the
apps repo, tars each app with a **stable filename** (change detection is
Etag-by-filename, a rename breaks upgrade tracking) and uploads to the
per-scope prefixes in the persistent apps bucket (in the `account` layer):

```sh
make sok-deploy-apps env=prod scope=all      # or scope=cm|sh|idx|shc
```

The same scopes are available from the **deploy-apps GitHub Action**
(workflow_dispatch → pick env + scope).

Only the **operator** pod reads the bucket (App Framework Download phase, via
IRSA, no static keys); Splunk pods receive apps via PodCopy. The CRs poll
every 600 s (`appsRepoPollIntervalSeconds`; unset/0 = polling disabled). Force
a poll via the `splunk-splunk-manual-app-update` ConfigMap in the namespace.

⚠ Deleting an archive does **not** uninstall the app (retire by shipping a
final version with `state = disabled`).

## Longer-term shape (decision D4 in the LLD)

The single apps repo is the bootstrap-era shape. The intended end state is
per-app repos (or a GitLab group) with a manifest + packaged-artifact channel
(S3) and cross-repo dispatch triggering `deploy-apps` on merge, recorded as an
open customer decision in the [LLD workbook](LLD-workbook.md).
