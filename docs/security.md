# Security & TLS

## Internal PKI

- The account layer creates an internal root CA (`pki_ca.tf`); cert+key live
  in the `ma-certs` bucket. Only the cert-issuer Lambda's role may read the
  **key** object; instances can read `ca/*.crt` only.
- At boot every node generates a private key + CSR locally and invokes
  `splunk-cert-issuer-<env>` (Lambda, `terraform/modules/cert_issuer`), which
  validates the CSR's CN/SANs against the cluster's DNS suffixes
  (suffix-spoof safe) and returns a CA-signed cert (730-day validity,
  SHA-512, serverAuth + clientAuth). The private key never leaves the node;
  the CA key never leaves the Lambda.
- Building the Lambda zip needs `python3 -m pip` on the machine running
  `terraform apply` (deps are cross-installed for the Lambda's
  aarch64/cp313 target).

## Verification modes

`ssl_verify_server_cert` (tfvars) renders into every node's
`[sslConfig] sslVerifyServerCert`:

- **`true` (prod)** — full verification of all cluster-internal TLS against
  the internal CA. Bootstrap **fails closed**: if the issuer Lambda is
  unreachable the instance exits instead of self-signing, and the ASG
  replaces it.
- **`false`** — nodes fall back to self-signed certs if the issuer is
  unavailable (`WARN: cert issuer unavailable` in `/var/tmp/startup.log`).
  Useful for bring-up/diagnosis only.

!!! note "SmartStore verifies against the OS bundle, not the internal CA"
    `remote.s3.sslRootCAPath` / `remote.s3.kms.sslRootCAPath` point at
    `/etc/pki/tls/certs/ca-bundle.crt` — AWS S3/KMS endpoints present
    Amazon-rooted certs, which the internal cluster CA can never validate.
    This is still full verification, just with the correct trust anchor.

## Secrets inventory

| Path | Created by | Purpose |
| --- | --- | --- |
| `/monitoring/splunk/license` | operator | Splunk Enterprise licence blob |
| `/monitoring/alerts/slack_webhook` | operator | Slack incoming webhook URL |
| `/monitoring/alerts/telegram` | operator | Telegram `{"bot_token","chat_id"}` (alerting no-ops until set) |
| `/git/login` | operator | Git PAT for `apps_git_repo` (bootstrap clones) |
| `/monitoring/splunk/password` | iam layer | `splunkadmin` password — fetched **on-instance** at boot to write `user-seed.conf`, so it never enters user-data or Terraform state |
| `/splunk/pass4SymmKey` | iam layer | shared cluster/SHC key |
| `/splunk/hec/aws-events` | account layer | HEC token for the EventBridge → HEC feed |
| `/splunk/secret/shc-<env>` | first SH/deployer boot | shared `splunk.secret` for all SHC members + deployer, so encrypted values in pushed bundles decrypt everywhere |
| `/splunk/secret/<hostname>` | first HF boot | per-HF stable `splunk.secret` (survives recycling) |

## Admin account

- The admin user is **`splunkadmin`** (`splunk_admin_username`), not `admin`.
- Retrieve the password on a node (never through your shell):
  `make password env=prod` prints the command.
- Rotate fleet-wide with `make rotate-admin env=prod` — the manager generates
  and stores the new value; peers re-auth using Secrets Manager version
  stages (`AWSPREVIOUS` → `AWSCURRENT`).

!!! warning "REST 401s are silent"
    splunkd REST returns `{"messages":[{"type":"ERROR","text":"Unauthorized"}]}`
    with no `entry` key on bad credentials — scripts that read
    `.entry | length` will see an empty list and report "0 results" instead
    of failing. Always assert `entry` exists (the repo scripts do).

## SOK (Kubernetes) posture

!!! note "SOK security is reviewed in depth elsewhere"
    This section records how the SOK posture diverges from the EC2 estate. The
    open SOK security findings and their fixes are in the
    [SOK review — Security](reviews/security.md); the operator model is in the
    [SOK overview](kubernetes-sok-overview.md).

When `deployment_model = "sok"` the security posture diverges deliberately from
the EC2 estate on two points — both documented, both revisited by the plan's
validation spikes.

**Admin user is `admin`, not `splunkadmin`.** The Splunk Operator's REST client
and its bundle-push exec hardcode the literal user `admin`
(`admin:$(cat /mnt/splunk-secrets/password)`). Renaming it would 401 every
operator call — and splunkd 401s are silent (the empty-`entry` trap above), so
CRs would never reach Ready with no useful error. Inside SOK the admin account
is therefore `admin`, populated from the same shared password
(`/monitoring/splunk/password`) via the operator global secret
`splunk-<ns>-secret`. To regain `splunkadmin` parity later, add it as an
*additional* user via an app — never replace `admin`.

**splunkd TLS verification is off inside the cluster (v1, temporary).** splunkd
on 8089 keeps Splunk's self-signed certs and `sslVerifyServerCert` stays
`false` between pods — a deliberate regression vs the EC2 estate's internal PKI,
until spike S3 delivers a private-PKI cert app. Hard constraints while it
stands: never set `requireClientCert` on 8089 and never disable splunkd TLS
(the operator presents no client cert and hardcodes `https` — either breaks
reconciliation). **SmartStore is *not* regressed:** S3/KMS TLS is fully verified
against the OS trust bundle via the SSE-KMS overlay (same anchor as EC2).

!!! warning "S2S ingest (9997) into SOK indexers is PLAINTEXT — known, accepted-for-now gap"
    On the EC2 estate splunk-to-splunk (S2S) forwarding on 9997 **is TLS**. On
    SOK it is **not**: 9997 into the SOK indexers is plaintext today, matching
    the operator default. This is an accepted gap for v1, not an oversight, and
    is tracked as **spike S3** (S2S TLS) alongside the 8089 verification work
    above. The intended fix is an SSL-enabled input (or an alternate port such
    as 9998) fronted by the future S2S NLB — **never plaintext 9997 through the
    NLB**. It stays a gap only until data-in-transit encryption for S2S becomes
    a requirement; today nothing forwards to SOK on 9997 (the HF edge is EC2 and
    points at EC2 peers, and no S2S NLB exists yet — see the
    [A3 note in the SOK lessons handoff](handoff-sok-lessons-remainder.md#a3-verify-no-plaintext-s2s-9997-into-sok)).

To summarise the three cluster-internal channels under SOK:

| Channel | Port | State under SOK | vs EC2 |
| --- | --- | --- | --- |
| S2S ingest (forwarder → indexer) | 9997 | **plaintext, not encrypted** (spike S3) | EC2 is TLS |
| splunkd management (pod → pod) | 8089 | TLS on, **verification off** (v1) | EC2 verifies against internal CA |
| SmartStore (indexer → S3/KMS) | 443 | **verified TLS** (OS trust bundle, SSE-KMS) | same anchor as EC2 |

### Certificate management options for SOK S2S (evaluated, NOT yet implemented)

Closing the S2S and 8089-verification gaps needs pod certificates signed by a
trusted CA, with the stable Splunk service DNS names as SANs. The four options
below were evaluated; the deciding factor is **where the CA private key lives**.
Nothing here is built yet — this is the design note for spike S3.

- **A — reuse the existing cert-issuer Lambda + private CA in S3 (RECOMMENDED).**
  Issue pod certs from the same internal CA the EC2 estate already uses (the
  cert-issuer Lambda in `terraform/modules/cert_issuer`, CA held in the
  `ma-certs` bucket), with the operator's stable service DNS names as SANs, and
  deliver them into the CR as a mounted Kubernetes Secret. The CA private key
  stays in the Lambda and never enters the cluster, so a pod compromise cannot
  reach it. One trust anchor across EC2 and SOK. Trade-off: certs are minted
  out-of-band, so rotation is a scheduled re-issue rather than automatic.
- **B — cert-manager in-cluster with our CA.** Run cert-manager and give it our
  CA as an `Issuer`; it auto-rotates pod certs on a schedule. Trade-off: the CA
  private key then lives **inside the cluster** (as a Secret cert-manager can
  read), widening the blast radius of a cluster compromise — the opposite of A.
- **C — AWS Private CA / ACM PCA.** Fully managed CA, strongest operational
  posture and audit trail, CA key held in a managed HSM. Trade-off: **cost** —
  roughly £320+/mo per CA even idle, hard to justify for a dev-first estate.
- **D — operator self-signed.** What we run today for 8089. No verifiable trust
  anchor, so it does not actually close the gap — listed only for completeness.

**Dev vs prod rhythm.** Dev re-mints certs for free on every nightly rebuild
(the cluster is destroyed and recreated, so fresh certs cost nothing and never
expire in place). Prod is long-lived, so option A needs a **scheduled re-issue**
(a cron/Lambda ahead of the cert validity window) rather than relying on the
rebuild to refresh them.

## Access model

- No SSH keys, no bastion: all shell access via **SSM Session Manager**.
- Splunk Web is reachable only through the `splunk-web` ALB, restricted to
  `trusted_cidrs`.
- SAML (Azure AD) is the intended login path; `splunkadmin` is break-glass.
- GitHub Actions authenticate to AWS via **OIDC** (no stored keys):
  `GitHubActionsTerraform` role, scoped to this repo.
