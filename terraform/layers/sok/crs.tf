###############################################################################
# The Splunk Enterprise custom resources (dev shape, see
# docs/kubernetes-sok-plan.md §1):
#   LicenseManager + MonitoringConsole + ClusterManager + IndexerCluster
#   (replicas floor-3) + Standalone search head, wired by refs.
#
# Built as HCL objects -> yamlencode -> kubectl_manifest (alekc provider,
# hashicorp's kubernetes_manifest cannot plan CRs against CRDs it hasn't
# seen). No enterprise.splunk.com/delete-pvc finalizer anywhere: the STOP
# path deletes PVCs explicitly, in order, while the CSI driver still exists.
#
# Probe overrides are day-one deliberate, credit: Gareth Anderson (SplunkTrust),
# Splunk Lantern "Splunk Operator for Kubernetes: Advanced operational learnings"
# + his "SOK lessons from our implementation" series (Medium): default probes
# kill busy indexers and pods mid-KV-store-migration -> unclean shutdowns ->
# SmartStore bucket-corruption risk. Only failureThreshold/periodSeconds/
# timeoutSeconds/initialDelaySeconds are CR-tunable.
###############################################################################

locals {
  # ~20-minute startup budget; liveness tolerant of load stalls.
  probes = {
    startupProbe = {
      initialDelaySeconds = 40
      periodSeconds       = 30
      timeoutSeconds      = 30
      failureThreshold    = 40
    }
    livenessProbe = {
      initialDelaySeconds = 30
      periodSeconds       = 30
      timeoutSeconds      = 30
      failureThreshold    = 30
    }
  }

  cm_probes = merge(local.probes, {
    livenessProbe = merge(local.probes.livenessProbe, { failureThreshold = 14 })
  })

  # Dev sizing: pods co-locate on a single t3.xlarge with Burstable QoS, CPU
  # request is low (250m) so the whole 1-indexer cluster + operator packs onto one
  # node to keep dev cheap; pods still burst to the 2-CPU limit under load, memory
  # request stays 2Gi (Splunk floor). Prod sets var.sok_pod_resources with
  # requests==limits for Guaranteed QoS (K7/NFR-1), the kubelet won't evict a
  # Guaranteed pod under node memory pressure, which matters for an indexer
  # mid-SmartStore-upload. Default null keeps the dev burstable shape byte-for-byte.
  resources = var.sok_pod_resources != null ? var.sok_pod_resources : {
    requests = { cpu = "250m", memory = "2Gi" }
    limits   = { cpu = "2", memory = "6Gi" }
  }

  # Per-role PVC sizing (NFR-6): the *_by_role maps override the global knobs
  # per role key; unset roles fall back to sok_{etc,var}_storage, so empty maps
  # (the default) keep today's uniform sizing byte-for-byte. Rationale: only the
  # indexers need a big var volume (SmartStore cache), LM/MC/CM idle at a
  # fraction of it (~$130/mo of over-provision on the prod shape). The operator
  # NEVER resizes PVCs, a size change on an existing cluster means recreate.
  storage_for = { for role in ["cm", "idxc", "sh", "shc", "lm", "mc"] : role => {
    etcVolumeStorageConfig = {
      storageClassName = local.storage_class
      storageCapacity  = lookup(var.sok_etc_storage_by_role, role, var.sok_etc_storage)
    }
    varVolumeStorageConfig = {
      storageClassName = local.storage_class
      storageCapacity  = lookup(var.sok_var_storage_by_role, role, var.sok_var_storage)
    }
  } }

  cr_common = {
    image     = local.splunk_image
    resources = local.resources
  }

  # Multisite (prod): one IndexerCluster CR per site, each pinned to its AZ; the
  # CM sits in site1's AZ. Empty for single-site (dev), a single idxc + a
  # Standalone SH instead. site1 = eu-west-2a, site2 = eu-west-2b.
  sites = var.multisite ? {
    site1 = "eu-west-2a"
    site2 = "eu-west-2b"
  } : {}

  # Indexers don't serve the web UI. Disabling splunkweb removes the "Waiting
  # for web server at :8000" step from `splunk start`, which was TIMING OUT on
  # the multisite peers (KV-store-upgrade 60s delay + SmartStore S3 init stack
  # up, so splunkweb bound too late), failing ansible's "Start Splunk via CLI"
  # after 5 retries -> exitCode 2 -> pod crashloop, peers never registering with
  # the CM. splunkd's mgmt port is up regardless; the UI is served by the SHC.
  # (String "0" so the ini writer emits a bare 0.)
  indexer_conf_overrides = [
    {
      key = "web"
      value = {
        directory = "/opt/splunk/etc/system/local"
        content   = { settings = { startwebserver = "0" } }
      }
    }
  ]

  # CM scheduling: multisite pins it to site1's AZ (nodeAffinity), and everywhere
  # it PREFERS a node without indexer pods (soft podAntiAffinity, credit Gareth
  # Anderson: co-located CM+indexer failed ungracefully; soft so dev's single
  # node still schedules).
  cm_anti_indexer = {
    podAntiAffinity = {
      preferredDuringSchedulingIgnoredDuringExecution = [{
        weight = 100
        podAffinityTerm = {
          topologyKey = "kubernetes.io/hostname"
          labelSelector = {
            matchLabels = { "app.kubernetes.io/name" = "indexer" }
          }
        }
      }]
    }
  }
  # merge-of-conditionals, NOT a ternary of differently-shaped objects, HCL
  # ternaries require type-unifiable branches (same trap as the SHC defaults).
  cm_affinity = merge(local.cm_anti_indexer, var.multisite ? local.affinity_for_zone["eu-west-2a"] : {})

  # requiredDuringScheduling nodeAffinity onto a specific AZ, precomputed per AZ.
  affinity_for_zone = { for z in ["eu-west-2a", "eu-west-2b", "eu-west-2c"] : z => {
    nodeAffinity = {
      requiredDuringSchedulingIgnoredDuringExecution = {
        nodeSelectorTerms = [{
          matchExpressions = [{
            key      = "topology.kubernetes.io/zone"
            operator = "In"
            values   = [z]
          }]
        }]
      }
    }
  } }
}

resource "kubectl_manifest" "license_manager" {
  yaml_body = yamlencode({
    apiVersion = "enterprise.splunk.com/v4"
    kind       = "LicenseManager"
    metadata   = { name = "lm", namespace = local.namespace }
    # web_proxy_defaults: ALB-fronted UI redirects (web-ingress.tf), {} when off.
    spec = merge(local.cr_common, local.storage_for["lm"], local.probes, local.web_proxy_defaults, {
      # CR volumes are mounted at /mnt/<name> in the Splunk pod.
      licenseUrl = "/mnt/licenses/enterprise.lic"
      volumes = [
        { name = "licenses", secret = { secretName = kubernetes_secret_v1.license.metadata[0].name } }
      ]
      monitoringConsoleRef = { name = "mc" }
    })
  })

  # The operator (and, transitively, the CRDs) must exist before any CR: the
  # CRD registers the kind, the operator reconciles it.
  depends_on = [kubernetes_secret_v1.global, helm_release.splunk_operator]
}

resource "kubectl_manifest" "monitoring_console" {
  yaml_body = yamlencode({
    apiVersion = "enterprise.splunk.com/v4"
    kind       = "MonitoringConsole"
    metadata   = { name = "mc", namespace = local.namespace }
    # web_proxy_defaults: ALB-fronted UI redirects (web-ingress.tf), {} when off.
    spec = merge(local.cr_common, local.storage_for["mc"], local.probes, local.web_proxy_defaults, {
      licenseManagerRef = { name = "lm" }

      # MC-local apps (scope local, mirrors the Standalone SH CR): the vendored
      # SplunkAdmins + TA-webtools land in the MC pod's etc/apps from the
      # mc-apps/ prefix. ⚠ applying this appRepo to a LIVE cluster restarts the
      # MC pod once (use make sok-apply, or land it before a nightly rebuild).
      # Acceptance needs a live-cluster test: deploy scope=mc -> app present in
      # the MC pod -> kill an indexer -> the peer re-appears in MC search without
      # a manual Apply.
      appRepo = {
        appsRepoPollIntervalSeconds = 600
        defaults                    = { volumeName = "appvol", scope = "local" }
        volumes                     = [local.appframework_volume]
        appSources = [
          { name = "mc-apps", location = "mc-apps/", scope = "local" },
        ]
      }
    })
  })

  depends_on = [kubernetes_secret_v1.global, helm_release.splunk_operator]
}

resource "kubectl_manifest" "cluster_manager" {
  yaml_body = yamlencode({
    apiVersion = "enterprise.splunk.com/v4"
    kind       = "ClusterManager"
    metadata   = { name = "cm", namespace = local.namespace }
    # web_proxy_defaults (ALB-fronted UI redirects, web-ingress.tf) rides inline
    # `defaults` and coexists with defaultsUrl, splunk-ansible merges both at
    # key level, so the CM's mounted defaults overlay is unaffected.
    # cm_affinity: zone pin (multisite) + SOFT anti-affinity away from indexer
    # pods, Anderson saw CM/indexer co-location fail ungracefully under load.
    # preferred (not required) so the single-node dev shape still schedules.
    spec = merge(local.cr_common, local.storage_for["cm"], local.cm_probes, { affinity = local.cm_affinity }, local.web_proxy_defaults, {
      serviceAccount       = kubernetes_service_account_v1.splunk_idx.metadata[0].name
      licenseManagerRef    = { name = "lm" }
      monitoringConsoleRef = { name = "mc" }

      defaultsUrl = "/mnt/defaults/default.yml"
      volumes = [
        { name = "defaults", configMap = { name = kubernetes_config_map_v1.cm_defaults.metadata[0].name } }
      ]

      # No secretRef on the volume -> IRSA (see irsa.tf). SSE-KMS + verified
      # TLS ride the defaults overlay (configmaps.tf), not expressible here.
      # provider/region are required by the CRD's CEL rule
      # ("region is required when provider is aws"); storageType s3 is explicit.
      smartstore = {
        defaults = { volumeName = "remote_store" }
        volumes = [
          {
            name        = "remote_store"
            endpoint    = "https://s3.${var.region}.amazonaws.com"
            path        = data.aws_s3_bucket.smartstore.bucket
            provider    = "aws"
            region      = var.region
            storageType = "s3"
          }
        ]
      }

      # Indexer apps ride the ClusterManager CR (IndexerCluster CRs take no
      # appRepo), scope cluster => the operator stages them and the CM pushes
      # them to peers via the cluster bundle. Polling every 600s (unset/0 =
      # polling DISABLED, the "default 3600" in the API comment is not
      # injected). Read by the operator via IRSA (appframework.tf).
      appRepo = {
        appsRepoPollIntervalSeconds = 600
        defaults                    = { volumeName = "appvol", scope = "cluster" }
        volumes                     = [local.appframework_volume]
        appSources = [
          # cluster scope -> CM stages, cluster bundle carries to the indexers
          # (repo manager-apps/). local scope -> the CM's own etc/apps (repo
          # apps/); per-source scope overrides the cluster default.
          { name = "idx-apps", location = "idx-apps/", scope = "cluster" },
          { name = "cm-apps", location = "cm-apps/", scope = "local" },
        ]
      }
    })
  })

  depends_on = [
    kubernetes_secret_v1.global,
    kubernetes_service_account_v1.splunk_idx,
    kubernetes_config_map_v1.cm_defaults,
    helm_release.splunk_operator,
  ]
}

# Single-site (dev): one IndexerCluster.
resource "kubectl_manifest" "indexer_cluster" {
  count = var.multisite ? 0 : 1
  yaml_body = yamlencode({
    apiVersion = "enterprise.splunk.com/v4"
    kind       = "IndexerCluster"
    metadata   = { name = "idxc", namespace = local.namespace }
    spec = merge(local.cr_common, local.storage_for["idxc"], local.probes, {
      replicas             = var.sok_indexer_replicas
      serviceAccount       = kubernetes_service_account_v1.splunk_idx.metadata[0].name
      clusterManagerRef    = { name = "cm" }
      licenseManagerRef    = { name = "lm" }
      monitoringConsoleRef = { name = "mc" }
      # Indexers don't serve the UI, disable splunkweb (see indexer_conf_overrides).
      defaults = yamlencode({
        splunk = { conf = local.indexer_conf_overrides }
      })
    })
  })

  depends_on = [kubectl_manifest.cluster_manager]
}

# Multisite (prod): one IndexerCluster CR per site, pinned to its AZ, with site
# defaults. replicas is PER-SITE (var.sok_indexer_replicas). ⚠ spike S0b must
# confirm the operator accepts replicas=2/site at origin:2 before prod node
# sizing is committed (#1131 vs Examples.md). Inline `defaults` is deliberate,
# the site assignment is immutable, never edited (the editable overlay lives on
# the CM's defaultsUrl ConfigMap).
resource "kubectl_manifest" "indexer_cluster_site" {
  for_each = local.sites

  yaml_body = yamlencode({
    apiVersion = "enterprise.splunk.com/v4"
    kind       = "IndexerCluster"
    metadata   = { name = "idxc-${each.key}", namespace = local.namespace }
    spec = merge(local.cr_common, local.storage_for["idxc"], local.probes, {
      replicas             = var.sok_indexer_replicas
      serviceAccount       = kubernetes_service_account_v1.splunk_idx.metadata[0].name
      clusterManagerRef    = { name = "cm" }
      licenseManagerRef    = { name = "lm" }
      monitoringConsoleRef = { name = "mc" }
      affinity             = local.affinity_for_zone[each.value]
      # A multisite peer needs [general] site = siteN in server.conf, the CM
      # rejects a peer with no site ("Master has multisite enabled but peer does
      # not have a site configuration" -> "clustering initialization failed").
      # splunk.site ALONE does not write it (splunk-ansible only emits the site
      # via the CM-only multisite_master path, which sets mode=disabled on a
      # peer, see the ClusterManager note). So write it explicitly, matching the
      # EC2 indexer.tpl ([general] site). The operator's own [general] pass4Symm-
      # Key survives (splunk-ansible's conf writer merges at key level). site is
      # immutable, so inline defaults (never edited) are correct here.
      defaults = yamlencode({
        splunk = {
          site = each.key
          conf = concat(local.indexer_conf_overrides, [
            {
              key = "server"
              value = {
                directory = "/opt/splunk/etc/system/local"
                content   = { general = { site = each.key } }
              }
            },
          ])
        }
      })
    })
  })

  depends_on = [kubectl_manifest.cluster_manager]
}

# Dev's standalone search head (enable_shc=false): a Standalone CR joined to the
# cluster via clusterManagerRef.
resource "kubectl_manifest" "search_head" {
  count = var.enable_shc ? 0 : 1

  yaml_body = yamlencode({
    apiVersion = "enterprise.splunk.com/v4"
    kind       = "Standalone"
    metadata   = { name = "sh", namespace = local.namespace }
    spec = merge(local.cr_common, local.storage_for["sh"], local.probes, local.web_proxy_defaults, {
      clusterManagerRef    = { name = "cm" }
      licenseManagerRef    = { name = "lm" }
      monitoringConsoleRef = { name = "mc" }

      # SH-local apps (scope local). ⚠ local-scope installs don't restart the
      # pod (#1402), the deploy path follows up with a restart when needed.
      appRepo = {
        appsRepoPollIntervalSeconds = 600
        defaults                    = { volumeName = "appvol", scope = "local" }
        volumes                     = [local.appframework_volume]
        appSources = [
          { name = "sh-apps", location = "sh-apps/", scope = "local" },
        ]
      }
    })
  })

  depends_on = [kubectl_manifest.cluster_manager]
}

# Prod search head cluster: 3 members at site0 (no search affinity). The
# operator creates the deployer for this CR. The KV store on these members is
# what the backup/restore mechanism (kvbackup.tf) targets. SHC apps ride the
# SHC CR from the shc-apps/ prefix (deployer -> members).
resource "kubectl_manifest" "search_head_cluster" {
  count = var.enable_shc ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "enterprise.splunk.com/v4"
    kind       = "SearchHeadCluster"
    metadata   = { name = "shc", namespace = local.namespace }
    spec = merge(local.cr_common, local.storage_for["shc"], local.probes,
      # site0 (multisite) and the ALB proxy web.conf must ride ONE defaults
      # blob, two merge args would clobber each other (later `defaults` wins).
      # The operator applies SHC-CR defaults to the deployer pods too, so an
      # exposed deployer UI gets the proxy conf for free.
      var.multisite || local.web_external_enabled ? {
        # SHs are site0; cluster_master_url comes from clusterManagerRef.
        # multisite_master is CM-only, see the IndexerCluster note above.
        defaults = yamlencode({
          splunk = merge(
            var.multisite ? { site = "site0" } : {},
            local.web_external_enabled ? { conf = local.web_proxy_conf } : {}
          )
        })
      } : {},
      # Spread SHC members across AZs so a single-AZ loss never takes the SHC/KV
      # majority (NFR-3). Its own merge arg (single-key ternary), a two-key
      # {…} : {} conditional fails Terraform type unification. SearchHeadCluster
      # CRD v4 supports topologySpreadConstraints (verified against the live CRD).
      # ScheduleAnyway is best-effort (no bring-up deadlock); switch to
      # DoNotSchedule for a hard 1-per-AZ guarantee once each AZ's capacity is set.
      var.multisite ? {
        topologySpreadConstraints = [{
          maxSkew           = 1
          topologyKey       = "topology.kubernetes.io/zone"
          whenUnsatisfiable = "ScheduleAnyway"
          labelSelector     = { matchLabels = { "app.kubernetes.io/instance" = "splunk-shc-search-head" } }
        }]
      } : {},
      {
        replicas             = 3
        clusterManagerRef    = { name = "cm" }
        licenseManagerRef    = { name = "lm" }
        monitoringConsoleRef = { name = "mc" }

        appRepo = {
          appsRepoPollIntervalSeconds = 600
          defaults                    = { volumeName = "appvol", scope = "local" }
          volumes                     = [local.appframework_volume]
          appSources = [
            { name = "shc-apps", location = "shc-apps/", scope = "local" },
          ]
        }
    })
  })

  depends_on = [kubectl_manifest.cluster_manager]
}
