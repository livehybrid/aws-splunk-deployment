# Sample Splunk C3 on AWS — Low-Level Design Workbook

This is designed to be used as a template to determine the appropriate implementation approach
and to highlight any missing components/features/design elements. 
The Splunk Validated Architecture C3: clustered indexers RF3/SF2 + 3-member SHC + CM/LM/Deployer/MC,
SmartStore on S3, on the Splunk Operator for Kubernetes (SOK) on EKS, is implemented as a
**reference build** in this repo.
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
| C4 | Acceptable indexing latency under peak? | Burstable vs fixed-CPU node types, pipelines | Cost-min build is a t3 node shape (Recommended for dev only) |  |
| C5 | Production node instance families: m6i/c6i (EBS cache) vs i3en/im4gn (NVMe cache)? ([Splunk reference hardware](https://docs.splunk.com/Documentation/Splunk/latest/Capacity/Referencehardware), [SVA tech brief](https://www.splunk.com/en_us/pdfs/tech-brief/splunk-validated-architectures.pdf)) | Cost vs cache performance | Default dev build runs a small t3 node and should be updated accordingly (x86-64 only — Splunk 10 needs AVX; no Spot for stateful indexer pods). |  |

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
| N4 | TLS: intra-cluster splunkd verification acceptable off in v1? Or customer PKI / cert-manager? | splunkd 8089 self-signed, `sslVerifyServerCert` off between pods (v1, spike S3); SmartStore S3/KMS fully verified against the OS bundle; external ALB uses ACM with DNS validation |  |
| N5 | Operator access: `kubectl exec`-only acceptable (no SSH)? Break-glass procedure? | `kubectl exec` via `make kexec`; no bastion, no keys in use |  |

### 1.4 Identity
| # | Question | Current default | **Customer decision** |
| --- | --- | --- | --- |
| I1 | IdP for Splunk Web (SAML)? Role/group mapping? | Not yet wired under SOK — ship as an app; local admin is break-glass |  |
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
| A2 | AZ-failure stance? (Data: RF3 across 3 AZs survives. Control plane: the CM pod is pinned to eu-west-2a — loss of 2a is a search outage until 2a capacity returns and the operator reschedules the CM) | |  |
| A3 | Region DR required? (SmartStore bucket is single-region; CRR possible for data redundancy but Splunk does not support active-active across regions) | None |  |
| A4 | Backup policy: KV store, $SPLUNK_HOME/etc on CM/Deployer? | SOK has kvstore backup process that can be scheduled (e.g. Github actions) |  |
| A5 | Maintenance windows, upgrade cadence (Splunk image + EKS version)? | Ad-hoc; Splunk via container-image bump per CR; EKS via `cluster_version` bump (gated on SOK supporting the target K8s version). |  |

### 1.7 Licensing & commercial
| # | Question | Current default | **Customer decision** |
| --- | --- | --- | --- |
| L1 | Licence size, term, who owns renewal + violations monitoring? | **Trial licence installed — must be replaced** |  |
| L2 | Who is named Splunk support contact / entitlement holder? | TBD |  |

### 1.8 Operations & security
| # | Question | Current default | **Customer decision** |
| --- | --- | --- | --- |
| O1 | Alert routing (Slack today) — customer ITSM integration? On-call? | SNS→Lambda→Slack |  |
| O2 | Node OS patching cadence + owner (node group AMI + container image) | Based on EKS AMI + Splunk container releases; cadence TBD |  |
| O3 | Vulnerability scanning / pen-test requirements? | None |  |
| O4 | Audit/compliance: audit-log retention, data classification? | Managed outside TF |  |
| O5 | Cost controls: the **nightly 21:30 UTC auto-stop workflow destroys the cluster** — Dev SOK only, performed by GitHub Action | Active |  |
| O6 | In-cluster event visibility: operator reconcile errors, pod crash-loops, the 6h KV-backup CronJob — sufficient signal, or ship K8s events into Splunk / add an ITSM hook? (OPS-4) | Open decision |  |
| O7 | Admin credential rotation: rotate by patching the operator global secret (never via Splunk CLI). Cadence? | Mechanism available; cadence undecided |  |
| O8 | CI deploy identity: the CI terraform role (OIDC, PowerUserAccess) drives start/stop/checks. Acceptable breadth, or least-privilege rewrite before production? (SEC-2) | PowerUser-based |  |

### 1.9 Decisions to schedule (not yet asked anywhere)

| # | Decision needed | **Customer decision** |
| --- | --- | --- |
| X1 | Index design: naming convention, per-sourcetype/per-team indexes, default retention per index |  |
| X2 | AWS account separation: TBD |  |
| X3 | HEC token policy: per-source tokens vs the shared defaults; token rotation |  |
| X4 | Syslog ingestion path (SC4S?) — currently none |  |
| X5 | UF estate deployment mechanism: this DS vs customer config management |  |
| X6 | Splunk upgrade policy (N-1?) and image-bump / EKS-version cadence; upgrade runbook is untested |  |
| X7 | pass4SymmKey / splunk.secret / HEC-token / git-PAT rotation cadence + ownership |  |
| X8 | Intra-cluster splunkd TLS: close the 8089-verification + S2S gaps (spike S3, cert-manager) — owner + timeline |  |
| X9 | ALB access logging + WAF: neither enabled today |  |
| X10 | Audit log retention period |  |
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
| AS6 | Current small t3 node shape is a **cost-minimised dev posture**, not the production size; no Spot for stateful indexer pods |
| AS7 | Trial licence in use; real entitlement exists and supports a remote LM |
| AS8 | Local `admin` (SOK's hardcoded operator user) acceptable as break-glass; SAML to be shipped as an app |
| AS9 | Public-IP + SG allowlist egress model acceptable (no NAT); nodes in the existing public subnets, SG-restricted |
| AS10 | splunkd 8089 verification off between pods acceptable in v1 (spike S3 closes it); SmartStore S3/KMS fully verified against the OS bundle |
| AS11 | `kubectl exec`-only access acceptable; no SSH/bastion |
| AS12 | XFS gp3 3000 IOPS/250 MBs adequate at this scale |
| AS13 | Nightly destroy/rebuild is acceptable (dev); SmartStore S3 is the only persistent data |
| AS14 | — (was IMDSv1-on-indexers; not applicable — pods reach S3/KMS via IRSA, IMDS is not involved) |
| AS15 | One local admin (`admin`) everywhere; humans to use SAML; no per-operator local accounts |
| AS16 | ALB access logs NOT enabled; no WAF |
| AS17 | No intra-cluster private PKI yet (spike S3) — compromise/regression posture is documented |
| AS18 | pass4SymmKey, splunk.secret, HEC token and git PAT have no rotation schedule; admin rotates by patching the operator global secret |
| AS19 | Splunk 10.4.0 image pinned; upgrades = image bump per CR (+ EKS version bump gated on SOK) |
| AS20 | All pods are cattle except CM/Deployer state (etc/, kvstore) which has a backup/restore process |
| AS21 | Only default indexes exist; HEC writes to `main`; no index design done |
| AS22 | Ingest is ~zero / demo data; all sizing/perf behaviour is unproven under load |
| AS23 | Nightly auto-stop (dev) assumes no overnight ingest or search requirement |
| AS24 | External forwarder clients reach the indexers over the static S2S NLB (9997, plaintext v1); indexer discovery is not supported on K8s |
| AS25 | GitHub.com hosts code + CI; runner egress to AWS via one PowerUser-grade OIDC role |
| AS26 | Monitoring = CW alarms→Slack + MC dashboards; no SLOs, no paging |
| AS27 | UTC everywhere; NTP via AL2023 chrony defaults |
| AS28 | No data-residency constraint beyond UK (eu-west-2) assumed |

---

## 3. Risk register (current design)

| # | Risk | L | I | Mitigation / decision needed |
| --- | --- | --- | --- | --- |
| R1 | Trial licence → search lockout imminent | H | H | Install Enterprise licence (in flight) |
| R2 | Burstable CPU credit exhaustion under sustained ingest (t3 nodes) | H | M | Production node sizing decision before real load (NFR-2) |
| R3 | CM pod pinned to eu-west-2a; loss of 2a = search outage until 2a capacity returns and the operator reschedules | M | M | Fast node replacement in 2a; treat 2a loss as P1; roadmap item to make the CM AZ-flexible |
| R4 | No region DR; S3 single-region | L | H | A3 decision; CRR + IaC redeploy runbook if required |
| R5 | A misclicked prod SOK stop destroys the live cluster mid-day | M | H | Typed `confirm=prod` gate (done); `environment: prod` required reviewers (open, DEP-5) |
| R6 | EKS 1.34 standard support ends 2026-12-02 → 6× control-plane bill if not upgraded | M | M | Own the 1.34→1.35 upgrade; 2026-11-01 go/no-go, gated on SOK release (NFR-4) |
| R7 | Public S2S/HEC/web endpoints + public EKS API, SG/CIDR allowlist is the only gate | M | M | N1/N2 decisions; tighten prod SGs (SEC-1); WAF on ALB optional |
| R8 | splunkd 8089 verification off + S2S 9997 plaintext (v1) — no intra-cluster private PKI yet | L | M | Spike S3: private-PKI cert app (cert-manager) closes both gaps |
| R9 | KV backup gates on SHC shape; dev Standalone KV wiped nightly with no copy | M | M | Prod SHC has a 6h CronJob (done); dev decision + drill cadence (NFR-8) |
| R10 | Node/pod loss degrades RF temporarily until the operator reschedules and RF/SF self-heals | M | L | On-demand only for indexers; RF/SF fixup + `sok-rf-remediate` |
| R11 | Single shared admin secret across all roles | M | M | Per-role creds or rotation policy (I2) |
| R12 | Unbounded S3 growth with no retention policy | H | M | C2/S3 decisions → lifecycle + index expiry |
| R13 | The `prevent_destroy` + versioning gap: the apps bucket was missed (smartstore + kvbackup are covered) | M | M | Add `prevent_destroy` + versioning to the apps bucket (SEC-4/DEP-10) |
| R14 | No Terraform state locking on some paths; nightly cron can race a local apply | M | M | `use_lockfile` added (DEP-1); align all TF to 1.11.1 (DEP-9) |

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

1. Walk the topology diagrams ([SOK overview](kubernetes-sok-overview.md)) — 45 min
2. Sizing & capacity (C1-C5, S1-S4) — decisions recorded in tfvars PR — 60 min
3. Network/access/identity (N*, I*) — 60 min
4. RACI design and sign-off, name owners — 90 min
5. Risk acceptance review (R1-R14) — 45 min
6. Go-live checklist draft: licence, node sizing apply, auto-stop disable (prod), intra-cluster TLS (spike S3), backups, runbooks
