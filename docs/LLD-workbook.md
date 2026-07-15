# Sample Splunk C3 on AWS — Low-Level Design Workbook

This is designed to be used as a template to determine the appropriate implementation approach
and to highlight any missing components/features/design elements. 
The Splunk Validated Architecture C3: clustered indexers RF3/SF2 + 3-member SHC + CM/LM/Deployer/MC + HF ingest
tier, SmartStore on S3 is implemented as a **reference build** in this repo.
This workbook captures everything the reference build *decided by default*
that an end user must ratify, change, or own.  
This is designed to be a workbook to be completed joinly with team members and stakeholders to 
ensure all requirements can be met, ideally an in-person workshop.
Record any decision, challenges and risks as appropriate.

---

## 1. Customer decisions required (questionnaire)

### 1.1 Capacity & sizing
| # | Question | Why it matters | Current default | **Customer decision** |
| --- | --- | --- | --- | --- |
| C1 | Average daily ingest (GB/day)? Peak day? Growth %/yr? | Indexer count/type, licence size, S3 cost | **Based on customer ingest** |  |
| C2 | Searchable retention per index/sourcetype? Archive/compliance retention? | SmartStore cache + S3 lifecycle + cost | **Undefined — nothing expires today** |  |
| C3 | Concurrent users? Scheduled search load? Premium apps (ES/ITSI)? | SH sizing; ES roughly doubles indexer needs | Assumed light ad-hoc search, no premium apps |  |
| C4 | Acceptable indexing latency under peak? | Burstable vs fixed-CPU instances, pipelines | Cost-min build is t3a.medium (Recommended for dev only) |  |
| C5 | Production instance families: m6i/c6i (EBS cache) vs i3en/im4gn (NVMe cache)? ([Splunk reference hardware](https://docs.splunk.com/Documentation/Splunk/latest/Capacity/Referencehardware), [SVA tech brief](https://www.splunk.com/en_us/pdfs/tech-brief/splunk-validated-architectures.pdf)) | Cost vs cache performance | Default dev build runs t3a.medium and should be updated accordingly. |  |

### 1.2 Storage
| # | Question | Current default | **Customer decision** |
| --- | --- | --- | --- |
| S1 | EBS type/IOPS/throughput for hot+cache? gp3 ok or io2? | gp3 3000 IOPS / 250 MB/s, 500 GB per indexer - should be adjusted based on customer retention / smartstore cache requirements. |  |
| S2 | Filesystem? Splunk lists ext3, ext4, btrfs and **XFS** as supported on Linux (a flat list, no recommended or preferred filesystem: [supported filesystems](https://docs.splunk.com/Documentation/Splunk/latest/Installation/Systemrequirements#Supported_file_systems)). **XFS** is the default used and can be overwritten with `data_volume_filesystem`) | XFS |  |
| S3 | SmartStore tiering: days before INTELLIGENT_TIERING? Glacier? Object Lock for compliance? ([SmartStore architecture](https://docs.splunk.com/Documentation/Splunk/latest/Indexer/AboutSmartStore), [S3 storage classes](https://docs.aws.amazon.com/AmazonS3/latest/userguide/storage-class-intro.html)) | IT after 30 days, no lock, no expiry |  |
| S4 | KMS: customer-managed CMKs? Rotation policy? Who holds key admin? | Per-env CMK created by Terraform, rotation on |  |

### 1.3 Network & access
| # | Question | Current default | **Customer decision** |
| --- | --- | --- | --- |
| N1 | Public-IP egress + SG allowlists vs NAT + private subnets (+ VPCe)? | Public IPs (~$3.65/mo each), SG `trusted_cidrs` allowlist, no NAT |  |
| N2 | Connectivity to customer networks (TGW/peering/VPN)? Who owns it? | None — internet + allowlist only |  |
| N3 | DNS: What domain root will be used? Who owns the zone? Who do we provide the NS to? | FQDN root to be specified and NS to be supplied to registrar/admin |  |
| N4 | TLS: internal self-managed CA acceptable for intra-cluster? Or customer PKI / public certs? | Internal root CA (Terraform) + issuing Lambda, 730-day certs (EC2 only currently); ALB uses ACM with DNS validation |  |
| N5 | Operator access: SSM-only acceptable (no SSH)? Break-glass procedure? | SSM-only; no bastion, no keys in use |  |

### 1.4 Identity
| # | Question | Current default | **Customer decision** |
| --- | --- | --- | --- |
| I1 | IdP for Splunk Web (SAML)? Role/group mapping? | Azure AD stanza exists, admin GUID per env (EC2 only, currently) |  |
| I2 | Local admin account policy + secret rotation cadence? | Single `admin` secret shared by all roles as part of TF build process. |  |
| I3 | AWS account access model (SSO, roles, who can assume what)? | Can be managed as unique account per env or single account for all depending on requirements. May need to configure AWS_PROFILE appropriately. |  |

### 1.5 Ingest
| # | Question | Current default | **Customer decision** |
| --- | --- | --- | --- |
| D1 | Ingest paths: UF→S2S? HEC? Syslog? Expected split? | S2S NLB (public, 443→9997) + HEC via ALB |  |
| D2 | Who deploys/owns UFs on sources? Who owns DS serverclasses? | External git repo used for all apps currently |  |
| D3 | useACK / persistent-queue requirements for loss tolerance? | no PQ sizing / useAck in place |  |
| D4 | App management model | current monorepo (`https://github.com/livehybrid/splunk-apps`, cloned at boot for EC2 approach). For SOK splunk-apps repo is synced to S3 - this process could be modified as required for per-app repos + CI (AppInspect) + version-pinned manifest + S3 artifact channel push? |  |
| D5 | Internal-log forwarding: which roles forward `_internal`/`_audit` to the indexers? | CM, SHC members and DS clients (license) forward via indexer discovery + useACK (`org_forward_to_indexers`); indexers are the destination, HFs use bootstrap outputs. Deployer/MC need validating currently |  |

### 1.6 Availability / DR
| # | Question | Current default | **Customer decision** |
| --- | --- | --- | --- |
| A1 | RTO/RPO for: search service, ingest, historical data? | Undefined |  |
| A2 | AZ-failure stance? (Data: RF3 across 3 AZs survives. Control plane: CM/LM/Deployer/MC pinned to one AZ, recover via ASG ~10 min) for EC2 deploy, SOK managed by EKS | |  |
| A3 | Region DR required? (SmartStore bucket is single-region; CRR possible for data redundancy but Splunk does not support active-active across regions) | None |  |
| A4 | Backup policy: KV store, $SPLUNK_HOME/etc on CM/Deployer? | SOK has kvstore backup process that can be scheduled (e.g. Github actions) |  |
| A5 | Maintenance windows, upgrade cadence (Splunk + OS + AMI)? | Ad-hoc; AMI via Packer pipeline, SOK image lift. |  |

### 1.7 Licensing & commercial
| # | Question | Current default | **Customer decision** |
| --- | --- | --- | --- |
| L1 | Licence size, term, who owns renewal + violations monitoring? | **Trial licence installed — must be replaced** |  |
| L2 | Who is named Splunk support contact / entitlement holder? | TBD |  |

### 1.8 Operations & security
| # | Question | Current default | **Customer decision** |
| --- | --- | --- | --- |
| O1 | Alert routing (Slack today) — customer ITSM integration? On-call? | SNS→Lambda→Slack |  |
| O2 | OS patching cadence + owner (SSM Patch Manager groups exist) | Tags set, no schedule attached, SOK TBD based on container releases |  |
| O3 | Vulnerability scanning / pen-test requirements? | None |  |
| O4 | Audit/compliance: CloudTrail retention, config rules, data classification? | Managed outside TF |  |
| O5 | Cost controls: the **nightly 22:30 UTC auto-stop workflow destroys the cluster** — for Dev SOK only, performed by Github Action | Active |  |
| O6 | Platform-event visibility (EC2): ASG lifecycle + spot interruption/rebalance events ship to HEC (EventBridge API destination, no Lambda) as `sourcetype=aws:events` — sufficient, or ITSM hook too? | Active |  |
| O7 | Admin credential rotation (EC2): `make rotate-admin` rotates fleet-wide via Secrets Manager version stages (password never transits operator shells). Cadence? | Mechanism built; cadence undecided |  |
| O8 | CI deploy identity: GitHubActionsTerraform role (OIDC, PowerUserAccess + scoped iam on Splunk*/splunk-* roles) drives start/stop/checks. Acceptable breadth, or least-privilege rewrite before production? | PowerUser-based |  |

### 1.9 Decisions to schedule (not yet asked anywhere)

| # | Decision needed | **Customer decision** |
| --- | --- | --- |
| X1 | Index design: naming convention, per-sourcetype/per-team indexes, default retention per index |  |
| X2 | AWS account separation: TBD |  |
| X3 | HEC token policy: per-source tokens vs the shared defaults; token rotation |  |
| X4 | Syslog ingestion path (SC4S?) — currently none |  |
| X5 | UF estate deployment mechanism: this DS vs customer config management |  |
| X6 | Splunk upgrade policy (N-1?) and AMI rebuild cadence; upgrade runbook is untested |  |
| X7 | pass4SymmKey / splunk.secret / HEC-token / git-PAT rotation cadence + ownership |  |
| X8 | CA lifecycle: root is 5y (1y early renewal), host certs 730d, no revocation — rotation runbook owner |  |
| X9 | ALB access logging + WAF: neither enabled today |  |
| X10 | CloudTrail / audit log retention period |  |
| X11 | Change control: who may run start/stop/rotate; PR approval rules; who holds repo access |  |
| X12 | Monitoring SLOs and alert thresholds (currently: TG health + CPU alarms → Slack) |  |
| X13 | Search RBAC / role quotas / user onboarding model |  |
| X14 | Forwarder-side TLS verification: UF clients currently must tolerate the internal CA (distribute CA bundle?) |  |
| X15 | Dev workspace purpose + data policy (synthetic vs prod copy); it has never been deployed |  |

---


## 2. Assumptions register (all require validation)

| # | Assumption baked into the build |
| --- | --- |
| AS1 | < 300 GB/day average ingest; no peak/burst profile supplied |
| AS2 | Retention is "forever" — no index expiry or S3 expiry configured |
| AS3 | Light search load; no ES/ITSI; ~handful of concurrent users |
| AS4 | Single region (eu-west-2);  **multisite indexer cluster**: site1=eu-west-2a, site2=eu-west-2b, 2 indexers per site. A whole-AZ loss leaves ≥1 copy of every bucket (origin:2,total:3). Region loss not covered |
| AS5 | site_replication_factor origin:2,total:3 / site_search_factor origin:1,total:2 meets durability/searchability needs; legacy pre-multisite buckets still governed by RF3/SF2. SHC remains 3 members across 3 AZs with site0 (no search affinity) |
| AS6 | Current t3a.medium fleet is a **cost-minimised dev posture**, not the production size; spot acceptable for dev only but spot-draught can cause startup failures. |
| AS7 | Trial licence in use; real entitlement exists and supports a remote LM |
| AS8 | Azure AD is the IdP; local `admin` acceptable as break-glass |
| AS9 | Public-IP + SG allowlist egress model acceptable (no NAT) |
| AS10 | Self-managed internal CA acceptable for intra-cluster TLS; 730-day certs; `sslVerifyServerCert` currently **off** |
| AS11 | [EC2 only] SSM-only access acceptable; no SSH/bastion |
| AS12 | XFS gp3 3000 IOPS/250 MBs adequate at this scale |
| AS13 | Nightly destroy/rebuild is acceptable (dev); SmartStore S3 is the only persistent data |
| AS14 | IMDSv1 on indexers tolerated until Splunk fixes SmartStore IMDSv2 (10.4 limitation) |
| AS15 | One local admin (`kadmin`) everywhere; humans to use SAML; no per-operator local accounts |
| AS16 | ALB access logs NOT enabled; no WAF |
| AS17 | Internal CA: 5y root / 730d host certs / no CRL-OCSP; compromise = rebuild |
| AS18 | pass4SymmKey, splunk.secret, HEC token and git PAT have no rotation schedule (admin password now rotatable via make rotate-admin) |
| AS19 | Splunk 10.4.0 pinned; upgrades = AMI rebuild + recycle (or equiv SOK action) |
| AS20 | All instances are cattle except CM/Deployer state (etc/, kvstore) which has a backup/restore process |
| AS21 | Only default indexes exist; HEC writes to `main`; no index design done |
| AS22 | Ingest is ~zero / demo data; all sizing/perf behaviour is unproven under load |
| AS23 | Nightly auto-stop assumes no overnight ingest or search requirement |
| AS24 | UF/forwarder clients are assumed not to verify server certificates (internal CA not distributed to sources) |
| AS25 | GitHub.com hosts code + CI; runner egress to AWS via one PowerUser-grade OIDC role |
| AS26 | Monitoring = CW alarms→Slack + MC dashboards; no SLOs, no paging |
| AS27 | UTC everywhere; NTP via AL2023 chrony defaults |
| AS28 | No data-residency constraint beyond UK (eu-west-2) assumed |

---

## 3. Risk register (current design)

| # | Risk | L | I | Mitigation / decision needed |
| --- | --- | --- | --- | --- |
| R1 | Trial licence → search lockout imminent | H | H | Install Enterprise licence (in flight) |
| R2 | Burstable CPU credit exhaustion under sustained ingest (t3a) | H | M | Production sizing decision before real load |
| R3 | Control plane single-AZ (CM/LM/Deployer/MC in 2a); AZ loss = no cluster admin/licence until ASG respawns elsewhere — currently pinned, won't respawn cross-AZ | M | M | Allow control-plane ASGs to span AZs (no AZ-bound EBS); ~small change |
| R4 | No region DR; S3 single-region | L | H | A3 decision; CRR + IaC redeploy runbook if required |
| R5 | Nightly auto-stop would destroy a production cluster | M | H | Disable schedule at go-live; gate on env tag |
| R6 | IMDSv1 enabled on indexers (SSRF credential surface) | L | M | Re-test on each Splunk upgrade; tracked in module var |
| R7 | Public S2S/HEC/web endpoints, SG CIDR allowlist is the only gate | M | M | N1/N2 decisions; WAF on ALB optional |
| R8 | CA private key compromise = silent cluster-wide MITM; no CA rotation runbook | L | H | Key is KMS-encrypted, Lambda-only read (fixed); write rotation runbook |
| R9 | No KV/etc backups (R/A unassigned) | M | M | Implement nightly backup to S3 (A4) |
| R10 | Spot reclamation degrades RF temporarily; eu-west-2 burstable spot droughts observed | M | L | Mixed-instances policy (capacity-optimized, multi-type) for dev; on-demand for prod |
| R11 | Single shared admin secret across all roles | M | M | Per-role creds or rotation policy (I2) |
| R12 | Unbounded S3 growth with no retention policy | H | M | C2/S3 decisions → lifecycle + index expiry |
| R13 | Hand-applied config dies on instance recycle (observed: MC search peers lost to a spot reclaim). Anything not in bootstrap or the apps repo is ephemeral | H | M | MC peer registration to bootstrap; enforce "no CLI-only config" rule |
| R14 | Config that only evaluates in the *stopped* state isn't exercised by normal CI (caused a failed stop apply) | M | M | Add a shutdown-overlay `terraform plan` to PR checks |

---

## 4. Reference documentation

| Topic | Source |
| --- | --- |
| Splunk Validated Architectures (C3 et al.) | https://www.splunk.com/en_us/pdfs/tech-brief/splunk-validated-architectures.pdf |
| System requirements / supported filesystems (lists XFS among supported, no preference stated) | https://docs.splunk.com/Documentation/Splunk/latest/Installation/Systemrequirements |
| Reference hardware & capacity planning | https://docs.splunk.com/Documentation/Splunk/latest/Capacity/Referencehardware |
| SmartStore architecture & cache sizing | https://docs.splunk.com/Documentation/Splunk/latest/Indexer/AboutSmartStore |
| SHC deployment requirements | https://docs.splunk.com/Documentation/Splunk/latest/DistSearch/SHCdeploymentoverview |
| Indexer cluster RF/SF concepts | https://docs.splunk.com/Documentation/Splunk/latest/Indexer/Basicclusterarchitecture |
| EBS gp3 performance/pricing | https://docs.aws.amazon.com/ebs/latest/userguide/general-purpose.html |
| S3 storage classes / Intelligent-Tiering | https://docs.aws.amazon.com/AmazonS3/latest/userguide/storage-class-intro.html |
| IMDSv2 (context for R6) | https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html |
| Public IPv4 pricing (context for N1) | https://aws.amazon.com/blogs/aws/new-aws-public-ipv4-address-charge-public-ip-insights/ |

## 5. Workshop agenda (suggested)

1. Walk the topology diagrams (README) — 45 min
2. Sizing & capacity (C1-C5, S1-S4) — decisions recorded in tfvars PR — 60 min
3. Network/access/identity (N*, I*) — 60 min
4. RACI design and sign-off, name owners — 90 min
5. Risk acceptance review (R1-R14) — 45 min
6. Go-live checklist draft: licence, sizing apply, auto-stop disable, ssl_verify flip, backups, runbooks
