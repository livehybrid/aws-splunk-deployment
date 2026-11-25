# TLS from AWS Private CA

Optional, off by default (`sok_private_ca_enabled = false`). Issues every Splunk
component's certificate from an existing **AWS Private CA (ACM PCA)** and has the
Splunk Operator wire it in, closing two gaps in the default deployment:

| Channel | Port | Default | With this enabled |
| --- | --- | --- | --- |
| splunkd management | 8089 | TLS, self-signed, peers do not verify | TLS, private-CA signed, `role: server` |
| S2S ingest | 9997 | plaintext | TLS, private-CA signed, `role: input` |

## How it works

SOK **3.2.0** added native certificate management: `spec.certs[]` on every Splunk
custom resource, with roles `server` (8089) and `input` (S2S 9997). The operator
mounts the referenced Secret and writes Splunk's TLS configuration itself.

```
ACM PCA (existing, passed in as acm_private_ca_arn)
  └── aws-privateca-issuer          IRSA role scoped to that one CA ARN
        └── cert-manager Certificate      one per Splunk CR, owned by this repo
              └── Secret: tls.crt / tls.key / ca.crt
                    └── spec.certs[] on the CR      the operator takes over here
```

Two details of the operator API decide this shape:

- **The operator's own auto-generation cannot use ACM PCA.** `issuerRef.kind` is
  an enum of exactly `Issuer` and `ClusterIssuer` with no `group` field, so it
  cannot point at an `AWSPCAClusterIssuer`. This repo therefore owns the
  `Certificate` objects and hands the operator the finished Secret, which is the
  path the operator documentation recommends anyway.
- **cert-manager's native Secret is exactly what the operator wants**
  (`tls.crt`, `tls.key`, `ca.crt`), so there is no combined-PEM assembly step.

## Enabling it

```hcl
sok_operator_chart_version = "3.2.0"   # or later; CRDs must be re-vendored to match
sok_private_ca_enabled     = true
acm_private_ca_arn         = "arn:aws:acm-pca:<region>:<account>:certificate-authority/<id>"
sok_private_ca_s2s_sans    = ["s2s.example.com"]  # the name forwarders dial
```

Two plan-time preconditions stop a half-configured apply: enabling below operator
3.2.0 (helm would silently drop the unknown `featureGates` value and the whole
feature would no-op), and enabling S2S TLS without an external SAN.

## Read before applying

**`role: input` is a cutover, not an addition.** The operator converts the
existing 9997 listener to TLS rather than adding a second port, so plaintext
forwarders stop the moment it applies. There is no side-by-side period; move
forwarders in step, or set `sok_private_ca_s2s_enabled = false` and do 8089 first.

**The toggle is not a complete rollback.** Removing a `spec.certs[]` entry stops
the operator managing it, but Splunk keeps serving the last certificate
indefinitely. Reverting a long-lived cluster needs a deliberate config change or
a rebuild.

**SANs must include what forwarders actually dial.** Through an NLB doing TCP
passthrough, TLS terminates on the pod but the forwarder connected to the NLB or
DNS name. Auto-derived SANs only ever cover in-cluster DNS, so that name has to be
listed in `sok_private_ca_s2s_sans` or forwarder verification fails.

**First apply may show a transient certificate error.** The `Certificate` objects
and the CRs are created in the same run and cert-manager fills the Secrets
asynchronously. A CR reconciled first reports it on status and retries.

## Not covered

The operator roles are `server` and `input` only. These stay as they were:

- **9887** indexer replication and **8191** KV store: no role exists. The
  certificate material is mounted in the pod, so a conf overlay can finish the
  job once the file layout under `/mnt/tls/splunk-server-tls-cert/` is confirmed
  on a running pod.
- **8000** and **8088** behind the ALB: encrypted, but an ALB never verifies a
  backend certificate in any configuration, so a private-CA certificate there
  would not change what is verified.

## Rotation

Deliberately unsolved, and worth deciding before relying on this anywhere
long-lived: **splunkd reads its certificate only at startup**, so the leaf
lifetime is also the Splunk restart cadence.

| Leaf (`sok_private_ca_leaf_duration`) | Renewal at ⅔ life | Restarts |
| --- | --- | --- |
| `168h`, the default | ~4.7 days | weekly |
| `2160h` | 60 days | quarterly |
| `8760h` | ~8 months | annual |

The default is `168h` only because that is the maximum a short-lived-mode CA will
issue, so it works against either CA mode. Set it deliberately once you know
which mode yours is.

Do not automate the restart on the indexers: an unattended restart skips
`splunk offline`, a leading cause of corrupted SmartStore buckets. Renewal is
automatic; the restart should stay manual and graceful.

Before production, enable encryption at rest for Kubernetes Secrets. The EKS
module used here does so by default (`create_kms_key = true`, `secrets` in
`encryption_config`); confirm it on your cluster.
