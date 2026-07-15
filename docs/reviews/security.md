# Security review — SOK implementation

!!! info "Part of the [full SOK review](index.md)"
    July 2026 · **8 findings** — 2 High, 3 Medium, 3 Low. High findings re-verified against code + live AWS. See the [review index](index.md) for the prioritised remediation plan and accepted-risk scope.

!!! warning "Remediation status (reconciled 2026-07-14)"
    **DONE 1 · PARTIAL 5 · OPEN 2.** The highest-severity items (SEC-1, SEC-2) are only *partly* closed — the mitigations in place are trust-scoping (SEC-2) and NetworkPolicies (SEC-5, the one DONE); prod SG tightening and PowerUser removal are still open. Open: SEC-7, SEC-8.

## Findings

### [SEC-1] Dev SOK runs with prod's admin password + cluster key inside the prod VPC — cross-environment blast radius
- **Severity**: High
- **Status**: ◐ **PARTIAL** — secret reads are now var-driven (`sok/secrets.tf:22-31` via `var.sok_secret_*_id`; `dev.tfvars:55-57` points dev at `/dev/splunk/*`) and a default-deny egress NetworkPolicy is added (`sok/networkpolicy.tf`, =SEC-5) (DONE). **Still OPEN: prod SG tightening** — HF `9997-9998` from `0.0.0.0/0` (`cluster/heavy-forwarder_sg.tf:38-47`), HF `8088` from the VPC CIDR (`:61-70`) — and no dev-own-VPC / private subnets.
- **Evidence**:
  - `terraform/layers/sok/secrets.tf:20-26` reads `/monitoring/splunk/password` and `/splunk/pass4SymmKey` with **no env in the path**; `:40-46` writes them into the dev cluster's K8s secret as `password`, `pass4SymmKey`, `idxc_secret`, `shc_secret` (mounted into every Splunk pod at `/mnt/splunk-secrets/password`).
  - Live: `aws secretsmanager list-secrets` returns a single account-global `/monitoring/splunk/password` and `/splunk/pass4SymmKey` (both tagged `Environment=prod`) — dev SOK and prod EC2 consume the identical values.
  - Dev nodes/pods sit in the **prod** VPC: `terraform/layers/eks/main.tf:24,69` + `_shared/vars/dev.tfvars:58` (`eks_vpc_name_tag = "prod"`); live prod subnets `default-a/b` are `192.168.10.0/26` & `.64/26` with `MapPublicIpOnLaunch=true`, so VPC-CNI gives pods `192.168.10.0/24` IPs.
  - Prod Splunk ingress open to that whole CIDR: `terraform/layers/cluster/heavy-forwarder_sg.tf:61-70` (HF **8088/HEC** from `var.default_vpc_cidr`), `heavy-forwarder_sg.tf:38-46` (HF **9997-9998/S2S** from `0.0.0.0/0`), `license_sg.tf:147-153` (LM **8089/splunkd-mgmt** from the VPC CIDR).
  - No `NetworkPolicy` anywhere (grep of `terraform/layers/sok`, `eks` → none); EKS default node SG allows all egress.
- **Impact**: Compromise of one dev pod — or anyone holding dev-cluster admin (the CI role in SEC-2, or `kubectl exec`) — yields the **production** Splunk admin password and the prod cluster `pass4SymmKey`. Because dev pods have prod-VPC IPs, they have an authenticated network path to prod License Manager `:8089` (full splunkd admin REST on a live prod node) and the prod HF ingest tier. The shared `pass4SymmKey`/`idxc_secret` also collapses the cluster-auth trust boundary between the two environments. A "disposable" dev environment therefore becomes a stepping stone into prod.
- **Recommendation**: Mint dev-only `/monitoring/splunk/password-dev` and `/splunk/pass4SymmKey-dev` (env-suffix the `secret_id` in `secrets.tf` like the buckets/keys already are); give dev its own VPC or at least private subnets so dev pods are not in the prod CIDR; add default-deny egress `NetworkPolicies`; scope prod LM `:8089` and HF `:8088` to specific source SGs instead of the whole VPC CIDR; delete the HF `9997-9998` `0.0.0.0/0` rule.
- **Effort**: M

### [SEC-2] GitHubActionsTerraform: PowerUser + IAM-role CRUD + EKS cluster-admin, trusted from any repo ref
- **Severity**: High
- **Status**: ◐ **PARTIAL** — the OIDC trust is now scoped to master only (`iam/github_actions_terraform.tf:31-35`, `StringEquals sub = repo:...:ref:refs/heads/master`) (DONE, the biggest leg). **Still OPEN: `PowerUserAccess` remains attached (`:44-47`); no permissions boundary; the `iam:CreateRole`/`PassRole` inline grants on `splunk-*` remain (`:49-134`).**
- **Evidence**:
  - `terraform/layers/iam/github_actions_terraform.tf:19-29` trust is `StringLike token…:sub = repo:livehybrid/aws-splunk-cluster:*` (any branch/tag/PR/environment) — confirmed live (`aws iam get-role GitHubActionsTerraform`).
  - `:37-40` attaches `PowerUserAccess`; `:42-83` inline-grants `iam:CreateRole/PutRolePolicy/AttachRolePolicy/DeleteRolePolicy` on `role/splunk-*` plus `iam:PassRole` on `Splunk*`/`splunk-*` (confirmed live: 1 managed `PowerUserAccess` + inline `passrole-splunk-profiles`).
  - `terraform/layers/eks/eks.tf:34-46` additionally grants this role an `AmazonEKSClusterAdminPolicy` EKS access entry.
- **Impact**: Any workflow that runs with `id-token: write` on **any** ref of the repo can assume a role that is effectively account-admin: PowerUser (kms:* → can decrypt all SmartStore data; s3 → read all buckets) + the ability to create/modify `splunk-*` IAM roles and PassRole them (a direct privilege-escalation path past PowerUser's `iam` exclusion) + full EKS cluster admin (read every K8s secret, including the prod Splunk password from SEC-1). A malicious PR/branch, a repo write compromise, or a poisoned workflow dependency escalates to full account compromise.
- **Recommendation**: Constrain the OIDC `sub` to specific refs/environments (e.g. `repo:livehybrid/aws-splunk-cluster:ref:refs/heads/master` and/or `:environment:prod`); replace `PowerUserAccess` with a scoped policy for exactly the layers CI manages; attach a permissions boundary so the `iam:CreateRole/PutRolePolicy` on `splunk-*` cannot mint a role more privileged than the boundary.
- **Effort**: M

### [SEC-3] Prod Splunk secrets land in the dev Terraform state bucket, which has no protective policy
- **Severity**: Medium
- **Status**: ◐ **PARTIAL** — a `DenyNonSSLAccess` policy now applies to the `…-terraform` bucket (`account/s3.tf:139-150`, `ssl_access` default true) (DONE). **Still OPEN: `encryption_type = "AES256"` (SSE-S3, not SSE-KMS); no reader restriction; the prod admin secret still transits state.** Note the account module predates the review, so live application may itself be a gap.
- **Evidence**:
  - `terraform/layers/sok/secrets.tf:34-49,53-61` create `kubernetes_secret_v1` resources whose `data` (prod admin password, `pass4SymmKey`, enterprise `license` blob, and `random_uuid.hec_token` at `:32`) Terraform persists **in cleartext** into `sok/terraform.tfstate`.
  - State lives in `livehybrid-splunk-dev-terraform` (`_shared/vars/dev.tfvars:12`). Live: that bucket has **no bucket policy** (`aws s3api get-bucket-policy` → "no bucket policy") and SSE-S3/`AES256` (not KMS). The **prod** state bucket, by contrast, carries the full `DenyNonSSLAccess` + `DenyIncorrectEncryptionHeader` + public-ACL denies.
- **Impact**: The production admin password and cluster symmetric key sit in a dev bucket with no TLS-only enforcement, no wrong-encryption deny, and only SSE-S3 (any principal with `s3:GetObject` decrypts transparently — no separate KMS key gate). The SEC-2 PowerUser role and any account admin can read them. Versioning is on, so old states retain historical secrets too.
- **Recommendation**: Apply the same hardened bucket policy (`DenyNonSSLAccess`) to the dev state bucket; convert both state buckets to SSE-KMS with a restricted key policy; restrict `s3:GetObject` to the CI role + break-glass; ideally let the operator generate the admin secret (or use an external-secrets flow) so the plaintext never transits Terraform state.
- **Effort**: M

### [SEC-4] Foundation S3 buckets (KV-store backups, SmartStore, apps) have versioning disabled
- **Severity**: Medium
- **Status**: ◐ **PARTIAL** — versioning is now enabled on smartstore (`smartstore.tf:101`) and kvbackup (`kvbackup.tf:44`), and the kvbackup lifecycle expires noncurrent versions separately (`:85-87`) (DONE for 2 of 3). **Still OPEN: the apps bucket has no versioning (`apps.tf`), and no Object Lock on kvbackup.**
- **Evidence**: Live `aws s3api get-bucket-versioning` returns empty (disabled) for `livehybrid-splunk-dev-splunk-kvbackup-dev`, `…-smartstore-dev`, and `…-apps-dev`; there is no `aws_s3_bucket_versioning` resource in `terraform/layers/sok-foundation/*.tf`. The kvbackup IRSA role has `s3:PutObject` (`sok/kvbackup.tf:55`) and the SmartStore role has `s3:DeleteObject` (`sok/irsa.tf:50-52`).
- **Impact**: The kvbackup bucket is the *only* durability layer for the SHC KV store (dashboards, lookups, user content — everything the nightly destroy wipes). With no versioning or Object Lock, a compromised kvbackup ServiceAccount, a script bug, or ransomware via the third-party image (SEC-6) can overwrite/corrupt backups with no recovery; the SmartStore role's `DeleteObject` can likewise irrecoverably wipe indexed data. The 30-day lifecycle expiry compounds a silent-corruption window.
- **Recommendation**: Enable versioning on all three foundation buckets; add S3 Object Lock (governance/compliance) on kvbackup; change the kvbackup lifecycle to expire *noncurrent* versions rather than the sole copy.
- **Effort**: S

### [SEC-5] No Kubernetes NetworkPolicies; unrestricted pod egress
- **Severity**: Medium
- **Status**: ✅ **DONE** — `sok/networkpolicy.tf` adds a default egress-deny (`policy_types=["Egress"]`, allowlisting intra-namespace + DNS + :443) that blocks prod Splunk ports; the enforcement agent is enabled via `eks/eks.tf:88` (`enableNetworkPolicy=true`).
- **Evidence**: No `kubernetes_network_policy`/`NetworkPolicy` in `terraform/layers/sok` or `eks` (grep → none). The EKS module's default node SG permits all egress; pods share the `splunk` namespace with no isolation.
- **Impact**: This is the control gap that makes SEC-1 exploitable laterally — any pod (operator, indexer, SH, or the kvbackup Job) can open connections to the entire prod VPC and the internet. No east-west segmentation between tiers either, so a single compromised container reaches everything.
- **Recommendation**: Add a default-deny `NetworkPolicy` in the `splunk` namespace plus explicit allows (intra-cluster Splunk ports, S3/STS egress); explicitly deny egress toward the prod Splunk SGs/CIDR.
- **Effort**: M

### [SEC-6] Container images pinned by mutable tag, not digest (incl. a third-party image with pod-exec + IRSA)
- **Severity**: Low
- **Status**: ◐ **PARTIAL** — the splunk image is digest-pinned (`variables.tf:423 @sha256:5fef…`) and the kvbackup `alpine/k8s` image is digest-pinned (`kvbackup.tf:165 @sha256:ec714…`) (DONE, incl. the sharpest one). **Still OPEN: `nodelocaldns` is still tag-only (`eks/nodelocaldns.tf:22`), and the alpine/k8s ECR-mirror is not done.**
- **Evidence**: `sok/kvbackup.tf:161` uses `alpine/k8s:1.34.1` (community image) for a Job that also holds `pods`/`pods/exec` RBAC (`sok/kvbackup.tf:89-106`) and IRSA to S3+KMS; `eks/nodelocaldns.tf:22` `registry.k8s.io/dns/k8s-dns-node-cache:1.26.8`; `_shared/variables.tf:423` `docker.io/splunk/splunk:10.4.0`. (Helm charts are version-pinned and the operator CRDs are vendored with a sha256 — good.)
- **Impact**: A repointed tag (registry/account compromise or typosquat) is pulled silently. The kvbackup Job is the sharpest: its image can `exec` into the Splunk pods (reading the mounted prod admin password) and read/write the backup bucket — a supply-chain path straight to SEC-1 + SEC-4.
- **Recommendation**: Pin images by `@sha256:` digest; mirror `alpine/k8s` into your own ECR (or replace with a minimal purpose-built kubectl+aws image) so a third party can't alter the most privileged Job's runtime.
- **Effort**: S

### [SEC-7] sok-checks leaves the ephemeral runner IP allowlisted on the EKS public API; permissive shared S3 endpoint
- **Severity**: Low
- **Status**: ○ **OPEN** — `sok-checks.yml:75` still appends the runner `/32` to `publicAccessCidrs` with no trailing/`always()` revert; the endpoint `GetObject`-on-`*` is unchanged.
- **Evidence**: `.github/workflows/sok-checks.yml:59-63` appends the runner's `/32` to the cluster's `publicAccessCidrs` via `aws eks update-cluster-config` and never reverts it (unlike `sok-stop.yml:83-86`, which is safe because the whole cluster is then destroyed). `account/vpc_default_ep.tf:14-22` second statement grants `s3:GetObject`/`ListBucket` on `*` from `Principal:*` (confirmed in the live endpoint policy), so the shared prod S3 endpoint is not itself a bucket-scoping control.
- **Impact**: After a checks run, a now-recycled shared runner IP retains *network* reachability to the dev EKS public endpoint until the nightly destroy (the API is still IAM/OIDC-gated, so no direct auth bypass — hence Low). The endpoint `GetObject`-on-`*` means bucket isolation between dev and prod rests entirely on IAM (which is correctly scoped here), not the endpoint.
- **Recommendation**: Have sok-checks revert its CIDR edit in a trailing/`always()` step (or use a private endpoint + self-hosted runner); scope the endpoint's second statement to owned bucket ARNs.
- **Effort**: S

### [SEC-8] `trusted_cidrs` defaults to `0.0.0.0/0` — latent public-exposure footgun
- **Severity**: Low
- **Status**: ○ **OPEN** — `_shared/variables.tf:35` still `default = ["0.0.0.0/0"]`; no validation added.
- **Evidence**: `_shared/variables.tf:33-36` `default = ["0.0.0.0/0"]`; `eks/main.tf:19` feeds it into `endpoint_public_access_cidrs` with `endpoint_public_access = true` (`eks/eks.tf:27-28`), and it also gates the Splunk web ALB (`cluster/splunk_web_alb.tf`). Both live workspaces override it to a /32 (`dev.tfvars:124-126`), so it is not currently exploitable. (Also: nodes run in public subnets with public IPs — SG-mitigated, and an accepted estate constraint since there is no NAT.)
- **Impact**: A new/misconfigured workspace that forgets `trusted_cidrs` silently exposes the EKS public API and Splunk Web to the entire internet.
- **Recommendation**: Remove the default (force an explicit value) or default to `[]` with a validation that rejects empty / `0.0.0.0/0` for the public-endpoint path.
- **Effort**: S

## Strengths
- **IRSA done right, no static keys**: every trust policy pins `:sub` to the exact `system:serviceaccount:<ns>:<sa>` and `:aud = sts.amazonaws.com` (`sok/irsa.tf`, `appframework.tf`, `kvbackup.tf`, `eks/eks.tf`, `eks/addons.tf`); each role's S3/KMS actions are scoped to the workspace bucket + key ARNs (no `s3:*`/`Resource:*`). Trust policies are re-derived from the live OIDC provider each rebuild.
- **Secure EKS-module defaults left intact (verified in the vendored module + live)**: K8s Secrets are envelope-encrypted with a dedicated KMS key (`encryption_config` default `{resources=["secrets"]}`), KMS key rotation on, and node **IMDSv2 required with hop-limit 1** — which blocks pod→node-IMDS credential theft.
- **Foundation buckets**: public access block fully on, SSE-KMS enforced, and bucket policies deny non-TLS, wrong-KMS-key, and public ACLs (verified live on smartstore + kvbackup). SmartStore KMS key is `prevent_destroy` with rotation enabled (365d).
- **Verified TLS to S3 inside Splunk**: the SmartStore overlay sets `remote.s3.sslVerifyServerCert = true` + OS CA bundle + `sse-kms` (`sok/configmaps.tf:22-30`) — no plaintext, no cert-verification bypass.
- **Credential hygiene in scripts**: admin password is always read inside the pod from the mounted secret, never on argv (`sok-health.sh`, `sok-kvstore-backup.sh/-restore.sh`, `sok-stop.yml`); package-apps.sh scrubs the git token from output.
- **Prod indexer/manager/SH Splunk ports are SG-scoped to role SGs**, not the VPC CIDR — so dev pods cannot reach the prod indexers/CM/SH (only the LM and HF are VPC-CIDR-open, per SEC-1). EC2/SOK exclusivity guards prevent two cluster managers against one SmartStore bucket.
- CI workflows use constrained `choice` inputs via env-var indirection — no shell-injection surface from `inputs`.

## Suggested follow-up tasks (ordered)
1. Env-scope the dev Splunk admin password + `pass4SymmKey` (stop dev SOK reading the prod-tagged `/monitoring/splunk/password` and `/splunk/pass4SymmKey`). [SEC-1]
2. Add default-deny NetworkPolicies in the `splunk` namespace and block egress to the prod Splunk SGs/CIDR. [SEC-5, SEC-1]
3. Tighten prod SGs: delete the HF `9997-9998` `0.0.0.0/0` rule; move LM `:8089` and HF `:8088` off the whole-VPC CIDR to specific SGs. [SEC-1]
4. Scope the `GitHubActionsTerraform` OIDC trust to a branch/environment and replace `PowerUserAccess` with a least-privilege policy + permissions boundary. [SEC-2]
5. Apply the TLS-only bucket policy to the dev Terraform state bucket and move state to SSE-KMS with restricted readers. [SEC-3]
6. Enable versioning on the three foundation buckets and add Object Lock on kvbackup. [SEC-4]
7. Pin all container images by digest; mirror/replace the `alpine/k8s` community image used by the kvbackup Job. [SEC-6]
8. Make sok-checks revert its EKS CIDR edit at job end; remove the `0.0.0.0/0` default on `trusted_cidrs`. [SEC-7, SEC-8]
