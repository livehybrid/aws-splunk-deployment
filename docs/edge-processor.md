# Splunk Edge Processor on EKS

The `ep` layer runs Splunk Edge Processor instances on the SOK cluster with
Splunk's own Helm chart,
[`splunk/edge-processor`](https://github.com/splunk/edge-processor-helm-charts/tree/main/charts/edge-processor),
one release per Edge Processor, each behind its own NLB.

It deploys the **data plane only**. The control plane, where pipelines are
written and instances are managed, already exists elsewhere:

- a Splunk Cloud Platform tenant, or
- a Splunk Enterprise 10.0+ data management control plane (customer-managed
  platform). The chart and install procedure are the same for both.

Everything the layer needs from the control plane comes from one screen:
**Edge Processors → the processor → Actions → Install/Uninstall → Instance
type: Kubernetes**.

Off by default (`ep_enabled = false`), in which case the layer plans empty.

## What gets created

```
                   senders (UFs/HFs :9997, HEC :8088, syslog :10514 tcp+udp)
                                  │
                        NLB (internal by default)
                  one per processor, IP targets, cross-zone
                                  │
  namespace splunk-edge ──────────┼───────────────────────────────────
                                  ▼
     StatefulSet ep-<key>   pods ep-<key>-0..N-1
       ├─ PVC ep-event-queue       (queue_size_gib, splunk-gp3-ext4)
       ├─ PVC ep-instance-identity (stable instance identity)
       └─ Secret ep-<key>-principal (mounted principal.yaml)
                  ▲
     Job ep-<key>-generate-principal-job  (eptools setup, once)
                                  │
                                  ▼
          control plane (Cloud :443, or Enterprise :8089)
          destinations (SOK indexers in-cluster, or elsewhere)
```

Per entry in `ep_processors`:

| Object | From | Notes |
|---|---|---|
| `helm_release.ep["<key>"]` | chart | StatefulSet, ClusterIP Service, principal Job, PDB, HPA (off), RBAC |
| `kubernetes_service_v1.nlb["<key>"]` | layer | `LoadBalancer`, class `service.k8s.aws/nlb`, handled by the ALB controller the sok layer installs |
| `aws_route53_record.ep["<key>"]` | layer | only when `hostname` is set |

Once per layer: the namespace and, with `sok_network_policies_enabled`, an
egress NetworkPolicy matching the one on the `splunk` namespace.

## Apply order

`account → eks → sok → ep`. Destroy in reverse. The sok layer provides the ALB
controller that builds the NLBs and the `splunk-gp3-ext4` StorageClass for the
queues. The nightly **SOK STOP** destroys `ep` before `sok` when it has state,
because only the controller can delete the NLBs it made.

## Deploying

### 1. Collect the values

On the control plane, open the processor's Install/Uninstall page with
instance type Kubernetes. The generated `helm install` command carries:

| Value | Layer input |
|---|---|
| `config.TENANT` | `ep_tenant` |
| `config.REGION` (if present) | `ep_region` |
| `config.ENV` (if present) | `ep_env` |
| `config.GROUP_ID` | `ep_processors.<key>.group_id` |
| `config.TOKEN` | a Secrets Manager secret, named in `ep_processors.<key>.token_secret_id` |

Copy them exactly as generated. The layer does not interpret them, so the same
inputs serve a Cloud tenant and an Enterprise control plane.

Also check the control plane's **shared settings** for the receiver ports. A
port changed there is not pushed into a running release, so `ep_ports` must
match.

### 2. Store the token

The token is sensitive. Keep it out of tfvars:

```sh
aws secretsmanager create-secret --name /dev/splunk/ep-token-main \
  --secret-string file://token.txt
```

Terraform reads it at plan time, so it ends up in the layer's state (as the SOK
secrets already do) and in the chart's own Secret in the cluster. It is used
once, by the principal Job; running instances authenticate with the principal.

### 3. tfvars

```hcl
ep_enabled = true
ep_tenant  = "<TENANT>"

ep_processors = {
  main = {
    group_id        = "<GROUP_ID>"
    token_secret_id = "/dev/splunk/ep-token-main"
    hostname        = "sok-dev-ep" # <label>.<sok_web_external_zone_name>
  }
}

# A Splunk Enterprise control plane inside the VPC on :8089, plus any
# off-cluster destinations (see Networking).
ep_egress_cidrs = ["10.0.0.0/16"]
```

### 4. Apply and verify

```sh
make -C terraform/layers/ep terraform env=dev
terraform -chdir=terraform/layers/ep output next_steps
```

The apply does not wait for the instances (`wait = false`). The chart's
principal Job has to finish before the pods can mount their Secret, and the
chart then allows each instance up to 30 minutes to open its metrics endpoint.
Follow the `next_steps` commands: the Job should be `Complete`, and the pods
`Running` and `Ready`. The instances then appear under the processor on the
control plane, where you apply pipelines as usual.

## Networking

**Receivers.** Forwarder (S2S) 9997, HEC 8088, syslog 10514 on both TCP and UDP,
all overridable in `ep_ports` (0 disables one). The NLB is a TCP/UDP
passthrough, so receiver TLS is whatever the control plane configures on the
instances; nothing terminates on the NLB. The TCP and UDP syslog ports share a
number, which the ALB controller turns into one `TCP_UDP` listener.

**Who can connect.** Internal by default, open to the VPC CIDR. Set
`ep_nlb_allowed_cidrs` to narrow it. An internet-facing NLB
(`ep_nlb_internet_facing`) is refused unless `ep_nlb_allowed_cidrs` is set
explicitly.

**Source IPs.** `ep_nlb_preserve_client_ip` (default true) keeps the sender's
address, which matters for syslog, where the source is the host. UDP always
preserves it.

**Why a separate Service.** The chart's Service is ClusterIP by default and
cannot set `loadBalancerClass`. The sok layer runs the ALB controller with its
Service mutator webhook off, so a plain `LoadBalancer` Service would fall to
the legacy in-tree controller. The layer's own Service sets the class, so the
AWS Load Balancer Controller builds the NLB with IP targets and a security
group. Subnets are passed explicitly (`default-a/b/c`, the same as the web ALB)
because the shared subnets carry no `kubernetes.io/role/*elb` tags.

**Egress.** With `sok_network_policies_enabled` (the estate default) the
namespace gets the same isolation as `splunk`: DNS, :443, in-cluster Services
and pods in the `splunk` namespace only. That covers a Splunk Cloud control
plane sending to the SOK indexers. A Splunk Enterprise control plane on :8089,
or indexers outside the cluster, need their CIDRs in `ep_egress_cidrs`; every
plan warns until that is set.

**No internet egress.** With `use_ecr_pullthrough_cache`, the instance and Job
image comes from the account's ECR Docker Hub cache (`docker-public`). The
control plane still has to be reachable: an Enterprise one inside the network
is, but a Cloud tenant needs a route out, or a proxy (`ep_extra_env`, for
example `HTTPS_PROXY`).

## Data safety

- Each instance queues to its own EBS volume, so a restarted pod keeps its
  queue and its identity.
- The chart never scales down (`selectPolicy: Disabled`). A removed instance
  takes any events still on its queue with it. Reduce `replicas` only after
  the instances have drained.
- PDB: `replicas - 1` must stay available (the chart's 2 of 3). At 2 replicas
  that is 1. At 1 there is no PDB, because it could only ever block node
  drains and the nightly teardown.
- **Destroying the layer deletes the namespace, the PVCs and any events still
  queued on them.** In dev that happens every night via SOK STOP.

## Sizing

The chart defaults apply per instance: requests 1 vCPU and 2 GiB, limits
2 vCPU and 4 GiB (`ep_resources`). Three instances therefore ask for 3 vCPU
and 6 GiB of the general pool, plus a 15 GiB gp3 volume each. On a small
general pool (the default is two t3.xlarge nodes, shared with Splunk), run two
instances with smaller requests, or give Edge Processor its own node group and
point `ep_node_selector` at it.

Autoscaling (`ep_autoscaling_enabled`) is off because the eks layer installs
no metrics-server, and without one the HPA never acts. With one installed, the
chart's HPA only scales up, from `replicas` to `max_replicas`.

## Upgrading the chart

The principal Job is part of the release, not a Helm hook, and a Job's pod
template is immutable. A change to its image (a new `ep_chart_version`, or
toggling `use_ecr_pullthrough_cache`) makes `helm upgrade` fail on the Job.
Delete the completed Job first:

```sh
kubectl -n splunk-edge delete job ep-<key>-generate-principal-job
```

The upgrade then recreates it, and it runs `eptools setup` again with the
token. The script generates the new principal before touching the Secret, so
an expired token fails the Job and leaves the working principal in place.
Instances roll one at a time.

## Private CA

Edge Processor's receiver certificates (S2S and HEC TLS) are uploaded to the
control plane and pushed to instances by it, not mounted from Kubernetes. The
cert-manager and AWS Private CA plumbing in the sok layer
([private-ca-tls.md](private-ca-tls.md)) therefore cannot feed them directly.
Issue from the private CA, then upload through the control plane.

## Open questions

These are unproven until the layer is stood up:

1. **Enterprise control plane end to end.** The chart and install procedure
   are the same for Cloud and Enterprise. What `TENANT`, `REGION` and `ENV`
   hold for an Enterprise control plane is whatever its install command
   generates. Nothing here has run against one yet.
2. **Control plane certificate trust.** The chart has no way to mount a CA
   bundle. If an Enterprise control plane's :8089 certificate is self-signed
   or from a private CA, it is not yet known how instances are told to trust
   it (the Linux install may carry this in its generated command).
3. **Proxy support.** Whether `eptools` and the instance honour
   `HTTPS_PROXY`.
4. **NLB behaviour.** Whether the `TCP_UDP` syslog listener and client IP
   preservation work together with the controller-managed security groups.
5. **Instance host names.** The chart sets `MACHINE_HOSTNAME` to the node
   name, so two instances on one node report the same host. Anti-affinity is
   only preferred, so this happens whenever instances outnumber nodes.
