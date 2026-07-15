# Troubleshooting (hard-won)

Every entry here was hit for real on this deployment. Newest first.

## Clustering / SmartStore

| Symptom | Cause / fix |
| --- | --- |
| Multisite: RF never met for old buckets, fixups say `Missing={ siteN:1 }` | Legacy non-site buckets follow the single-site `replication_factor` but are constrained to one site by default — impossible when RF > peers-per-site. The CM template sets `constrain_singlesite_buckets = false` (multisite only) |
| Cold boot: RF/SF stuck, fixups stall on "No possible srcs for replication" / "Missing enough suitable candidates", CM logs `CMSendMetadataJob … Connect Timeout` | Indexer↔indexer **8089** missing from the SGs. SmartStore warm-bucket *metadata* replication posts to the peer mgmt port; 9887 streaming alone only covers hot buckets, so it never shows until a cold boot against a populated bucket. Fixed by `port_8089_indexers_{from,to}_self`; `scripts/rf-remediate.sh` remains as a stall safety net |
| SmartStore uploads fail with 502s, health otherwise green | `sslVerifyServerCert` validating AWS endpoints against the **internal** CA. S3/KMS need the OS trust bundle: `remote.s3.sslRootCAPath = /etc/pki/tls/certs/ca-bundle.crt` (and the `kms.` twins) |
| KMS encryption setting silently not applied | The canonical key is `remote.s3.kms.key_id` — the underscore form `kms_key_id` is ignored without error. Also note the S3 client only reloads on a splunkd restart |
| SmartStore can't fetch AWS creds though `curl` to IMDS works | Splunk 10.4's S3 client can't do IMDSv2 — indexers run `imds_http_tokens = "optional"` (indexers **only**) |
| Indexers log `cannot reach manager`, CLI gets connection refused on 8089 | `disableDefaultPort = true` fossil in server.conf disabled mgmt REST entirely (now removed from manager/deployer/MC templates) |

## Bootstrap / SHC

| Symptom | Cause / fix |
| --- | --- |
| splunkd wedged, `Unable to read splunk.secret` | empty splunk.secret — the get-secret helper needs the AWS CLI (**boto3 is NOT on the AMI**); templates guard `[ -s ... ]` now |
| `init shcluster-config` → "Connection reset by peer" | bare TCP check on 8089 passes before REST is ready; templates poll `/services/server/info` and retry init |
| Cluster names don't resolve for ~15 min on cold start | VPC resolver caches NXDOMAIN for the SOA negative TTL (Route53 default 900s; set to 60s on the private zone) |
| MC loses its search peers after an instance recycle | Hand-applied config dies with the instance (risk R15). The MC now runs a convergent reconciler on a systemd timer — anything else configured by hand on a node will not survive |

## REST / tooling

| Symptom | Cause / fix |
| --- | --- |
| REST queries return empty lists that should have content | **Silent 401**: splunkd returns `{"messages":[{"type":"ERROR","text":"Unauthorized"}]}` which parses fine and yields `entry = []`. The admin user is `splunkadmin`, not `admin`. Assert the `entry` key exists |
| `make` targets pause on a `q`-to-quit screen | AWS CLI v2 client pager; every script exports `AWS_PAGER=""` |
| GH Actions step "passes" despite failures inside `cmd | tee` | Default runner shell has no pipefail — set `shell: bash` on the step |
| Terraform in Actions: "no EC2 IMDS role found" with valid OIDC | An explicit `profile` in provider config bypasses env-var creds; the workflows write OIDC creds into the **default profile** |

## Infrastructure

| Symptom | Cause / fix |
| --- | --- |
| Stop apply fails `InvalidIPAddress.InUse` releasing EIPs | EIP release races instance termination; the stop workflow retries once after 60s |
| Stop apply fails "Invalid index" on a data source | Count-gated resources referenced by ungated data sources only fail in the **off state**, which normal CI never plans (risk R16) |
| ASG stuck `Failed: insufficient capacity` on spot | Burstable spot pools (t3/t3a.medium) can drain region-wide; flip `use_spot=false` or change type |
| ALB CNAME apply fails `conflicts with other records` | Legacy per-role A records (manager/license) at the same names; bootstrap no longer registers them |
| ALB returns 504 on every endpoint | A consolidated SG was created with **no egress rules** — check `splunk_web_alb` SG has egress 8000/8088 |
