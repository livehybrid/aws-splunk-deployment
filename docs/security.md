# Security & TLS

This estate runs Splunk under the Splunk Operator for Kubernetes (SOK). The
open SOK security findings and their fixes are tracked in the
[SOK review, Security](reviews/security.md); the operator model is in the
[SOK overview](kubernetes-sok-overview.md).

## SmartStore verifies against the OS bundle

SmartStore S3/KMS TLS is fully verified against the **OS trust bundle**
(`/etc/pki/tls/certs/ca-bundle.crt`), not any internal cluster CA: AWS
endpoints present Amazon-rooted certs, which an internal cluster CA can never
validate. The SSE-KMS overlay pins:

- `remote.s3.encryption = sse-kms` with `remote.s3.kms.key_id` set to the
  workspace KMS key ARN (note: the canonical setting name is `kms.key_id`;
  the underscore form `kms_key_id` is **silently ignored** by Splunk).
- `remote.s3.sslVerifyServerCert = true` anchored to the OS trust bundle
  (and the `remote.s3.kms.` twins).

This is full verification, just with the correct trust anchor.

## Secrets inventory

| Path | Created by | Purpose |
| --- | --- | --- |
| `/monitoring/splunk/license` | operator | Splunk Enterprise licence blob |
| `/monitoring/alerts/slack_webhook` | operator | Slack incoming webhook URL |
| `/monitoring/alerts/telegram` | operator | Telegram `{"bot_token","chat_id"}` (alerting no-ops until set) |
| `/git/login` | operator | Git PAT for `apps_git_repo` (app packaging clones) |
| `/monitoring/splunk/password` | account/iam layer | prod Splunk admin password; seeds the operator global secret |
| `/<env>/splunk/password` | account/iam layer | env-scoped dev admin password (SEC-1: dev no longer holds prod creds) |
| `/splunk/pass4SymmKey` | account/iam layer | shared cluster/SHC key; seeds `pass4SymmKey`/`idxc_secret`/`shc_secret` |
| `/splunk/hec/aws-events` | account layer | HEC token for platform-event forwarding |

The operator populates the global secret `splunk-<ns>-secret` (keys:
`password`, `pass4SymmKey`, `idxc_secret`, `shc_secret`, `hec_token`) from
these. Rotate by patching the secret, never via the Splunk CLI.

## Admin account

!!! warning "SOK admin user is `admin`, not `splunkadmin`"
    The Splunk Operator's REST client and its bundle-push exec hardcode the
    literal user `admin` (`admin:$(cat /mnt/splunk-secrets/password)`). Renaming
    it would 401 every operator call, and splunkd 401s are silent (the
    empty-`entry` trap below), so CRs would never reach Ready with no useful
    error. Inside SOK the admin account is therefore `admin`, populated from the
    shared password via the operator global secret `splunk-<ns>-secret`. To add
    `splunkadmin` parity later, add it as an *additional* user via an app
    (never replace `admin`).

!!! warning "REST 401s are silent"
    splunkd REST returns `{"messages":[{"type":"ERROR","text":"Unauthorized"}]}`
    with no `entry` key on bad credentials, scripts that read
    `.entry | length` will see an empty list and report "0 results" instead
    of failing. Always assert `entry` exists (the repo scripts do).

## Cluster-internal TLS posture

When the estate runs, the security posture has two documented divergences, both
revisited by the plan's validation spikes.

**splunkd TLS verification is off inside the cluster (v1, temporary).** splunkd
on 8089 keeps Splunk's self-signed certs and `sslVerifyServerCert` stays
`false` between pods, until spike S3 delivers a private-PKI cert app. Hard
constraints while it stands: never set `requireClientCert` on 8089 and never
disable splunkd TLS (the operator presents no client cert and hardcodes
`https`, either breaks reconciliation). **SmartStore is *not* regressed:**
S3/KMS TLS is fully verified against the OS trust bundle via the SSE-KMS
overlay.

!!! warning "S2S ingest (9997) into the SOK indexers is PLAINTEXT, known, accepted-for-now gap"
    9997 into the SOK indexers is plaintext today, matching the operator
    default. This is an accepted gap for v1, not an oversight, and is tracked as
    **spike S3** (S2S TLS) alongside the 8089 verification work above. The
    intended fix is an SSL-enabled input (or an alternate port such as 9998)
    fronted by the future S2S NLB, **never plaintext 9997 through the NLB**.
    Today nothing forwards to SOK on 9997 (no S2S NLB exists yet).

To summarise the three cluster-internal channels:

| Channel | Port | State |
| --- | --- | --- |
| S2S ingest (forwarder → indexer) | 9997 | **plaintext, not encrypted** (spike S3) |
| splunkd management (pod → pod) | 8089 | TLS on, **verification off** (v1) |
| SmartStore (indexer → S3/KMS) | 443 | **verified TLS** (OS trust bundle, SSE-KMS) |

### Certificate management options for SOK S2S (evaluated, NOT yet implemented)

Closing the S2S and 8089-verification gaps needs pod certificates signed by a
trusted CA, with the stable Splunk service DNS names as SANs. The options below
were evaluated; the deciding factor is **where the CA private key lives**.
Nothing here is built yet, this is the design note for spike S3.

- **A: cert-manager in-cluster with a private CA (RECOMMENDED).** Run
  cert-manager and give it a private CA as an `Issuer`; it auto-rotates pod
  certs on a schedule with the operator's stable service DNS names as SANs,
  delivered into the CR as a mounted Kubernetes Secret. Trade-off: the CA
  private key lives inside the cluster (as a Secret cert-manager can read).
- **B: AWS Private CA / ACM PCA.** Fully managed CA, strongest operational
  posture and audit trail, CA key held in a managed HSM. Trade-off: **cost**
  (roughly £320+/mo per CA even idle, hard to justify for a dev-first estate).
- **C: operator self-signed.** What we run today for 8089. No verifiable trust
  anchor, so it does not actually close the gap (listed only for completeness).

**Dev vs prod rhythm.** Dev re-mints certs for free on every nightly rebuild
(the cluster is destroyed and recreated, so fresh certs cost nothing and never
expire in place). Prod is long-lived, so it needs a **scheduled re-issue**
(cert-manager handles this automatically) rather than relying on the rebuild to
refresh them.

## Access model

- No SSH keys, no bastion: all shell access via `kubectl exec` (`make kexec`).
- Splunk services are `ClusterIP` (internal); the default way in is a port
  forward. An opt-in per-component ALB can front the UIs, restricted to
  `sok_web_external_allowed_cidrs` (defaults to `trusted_cidrs`), see the
  [overview](kubernetes-sok-overview.md#external-access-splunk-web-via-alb-opt-in-per-component).
- Pods reach S3/KMS via **IRSA** (ServiceAccount-assumed IAM roles), no static
  keys anywhere.
- GitHub Actions authenticate to AWS via **OIDC** (no stored keys); the CI role
  lives in the `iam` layer, its trust scoped to this repo.
