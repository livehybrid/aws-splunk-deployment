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
  # CM always lives in the primary AZ (site1 for multisite, general-a for
  # single-site). Using an AZ-pinned StorageClass guarantees the EBS volume is
  # created in that AZ on first deploy, preventing the PVC/pod AZ mismatch that
  # requires manual PVC deletion when a fresh cluster assigns volumes randomly.
  # site1 always maps to the first AZ returned by the data source (index 0).
  # var.sok_cm_az overrides when you need the CM in a specific AZ (e.g. the
  # first AZ is constrained, or you want it in a non-default site).
  cm_az            = var.sok_cm_az != null ? var.sok_cm_az : data.aws_availability_zones.available.names[0]
  cm_storage_class = "splunk-gp3-xfs-${local.cm_az}"

  # When NVMe var storage is enabled the indexer SmartStore cache PVC uses the
  # local-path StorageClass backed by the RAID-0 NVMe mount. etc always stays
  # on EBS: it holds cluster membership state and must survive node replacement.
  idxc_var_storage_class = var.sok_indexer_nvme_var_storage ? "splunk-local-nvme" : local.storage_class

  storage_for = merge(
    { for role in ["sh", "shc", "lm", "mc"] : role => {
      etcVolumeStorageConfig = {
        storageClassName = local.storage_class
        storageCapacity  = lookup(var.sok_etc_storage_by_role, role, var.sok_etc_storage)
      }
      varVolumeStorageConfig = {
        storageClassName = local.storage_class
        storageCapacity  = lookup(var.sok_var_storage_by_role, role, var.sok_var_storage)
      }
    } },
    # idxc split out so var can use NVMe StorageClass when enabled.
    # etc always on EBS (cluster membership state must survive node replacement).
    { idxc = {
      etcVolumeStorageConfig = {
        storageClassName = local.storage_class
        storageCapacity  = lookup(var.sok_etc_storage_by_role, "idxc", var.sok_etc_storage)
      }
      varVolumeStorageConfig = {
        storageClassName = local.idxc_var_storage_class
        storageCapacity  = lookup(var.sok_var_storage_by_role, "idxc", var.sok_var_storage)
      }
    } },
    { cm = {
      etcVolumeStorageConfig = {
        storageClassName = local.cm_storage_class
        storageCapacity  = lookup(var.sok_etc_storage_by_role, "cm", var.sok_etc_storage)
      }
      varVolumeStorageConfig = {
        storageClassName = local.cm_storage_class
        storageCapacity  = lookup(var.sok_var_storage_by_role, "cm", var.sok_var_storage)
      }
    } },
    # Per-key storage entries for named SH/SHC instances. Each key falls back to
    # the base "sh"/"shc" sizing (sok_{etc,var}_storage_by_role["sh"/"shc"] or
    # the global default), so the common case needs no per-instance override.
    { for k in keys(local.sh_map) : "sh-${k}" => {
      etcVolumeStorageConfig = {
        storageClassName = local.storage_class
        storageCapacity  = lookup(var.sok_etc_storage_by_role, "sh-${k}", lookup(var.sok_etc_storage_by_role, "sh", var.sok_etc_storage))
      }
      varVolumeStorageConfig = {
        storageClassName = local.storage_class
        storageCapacity  = lookup(var.sok_var_storage_by_role, "sh-${k}", lookup(var.sok_var_storage_by_role, "sh", var.sok_var_storage))
      }
    } },
    { for k in keys(local.shc_map) : "shc-${k}" => {
      etcVolumeStorageConfig = {
        storageClassName = local.storage_class
        storageCapacity  = lookup(var.sok_etc_storage_by_role, "shc-${k}", lookup(var.sok_etc_storage_by_role, "shc", var.sok_etc_storage))
      }
      varVolumeStorageConfig = {
        storageClassName = local.storage_class
        storageCapacity  = lookup(var.sok_var_storage_by_role, "shc-${k}", lookup(var.sok_var_storage_by_role, "shc", var.sok_var_storage))
      }
    } }
  )

  # Resolve the effective SH and SHC maps, applying the enable_shc fallback when
  # both new maps are empty so existing tfvars that only set enable_shc keep working.
  legacy_shape = length(var.sok_standalone_search_heads) == 0 && length(var.sok_search_head_clusters) == 0

  sh_raw  = local.legacy_shape ? (var.enable_shc ? {} : { default = {} }) : var.sok_standalone_search_heads
  shc_raw = local.legacy_shape ? (var.enable_shc ? { default = {} } : {}) : var.sok_search_head_clusters

  # ⚠ Rebuild both maps attribute-by-attribute, do NOT consume *_raw directly.
  # A conditional expression UNIFIES the types of its branches, so unifying
  # map(object({app_location=string, replicas=number})) with the untyped
  # `{ default = {} }` legacy fallback collapses the whole value to
  # map(map(string)): a map has ONE element type, so replicas = 3 silently
  # becomes the string "3". yamlencode then emits `replicas: "3"` and the CRD
  # rejects the CR:
  #   spec.replicas in body must be of type integer: "string"
  # It only bit the shape that sets replicas explicitly (dev.tfvars); leaving
  # replicas unset kept the number-typed literal default, which is why prod
  # applied cleanly. Reconstructing here re-asserts the types (tonumber) and
  # resolves the per-key defaults once, so every consumer gets concrete,
  # correctly-typed values whatever the branches happen to unify to.
  sh_map = { for k, v in local.sh_raw : k => {
    app_location = try(v.app_location, null) != null ? tostring(v.app_location) : "sh-${k}-apps/"
  } }

  shc_map = { for k, v in local.shc_raw : k => {
    app_location = try(v.app_location, null) != null ? tostring(v.app_location) : "shc-${k}-apps/"
    replicas     = try(v.replicas, null) != null ? tonumber(v.replicas) : 3
  } }

  # Per-role image, so a Splunk upgrade can be staged ONE ROLE AT A TIME instead
  # of rotating the whole estate off a single variable.
  #
  # The operator does already sequence a multi-CR image change by itself
  # (docs/SplunkOperatorUpgrade.md: operator pod -> Standalone -> LicenseManager
  # -> ClusterManager -> SearchHeadCluster -> IndexerCluster -> MonitoringConsole,
  # conditional on the CRs being linked by refs, which ours are). Two reasons to
  # want manual staging anyway:
  #   1. That order puts Standalone SECOND, ahead of the LM and CM, so a search
  #      head briefly runs a newer build than the manager it peers to. Not what
  #      you would choose for a first upgrade on a production estate.
  #   2. The doc frames the ordering around an OPERATOR release shipping a new
  #      Splunk image, not around changing spec.image from Terraform. Probably
  #      the same code path; not verified, and the only upgradePhase status field
  #      in the vendored CRDs is on SearchHeadCluster.
  # Setting one role at a time and applying between each is deterministic and
  # depends on none of that. It also allows canarying a build on one SH first.
  #
  # Fallback chain mirrors storage_for: the exact key, then the generic role key,
  # then the global var.sok_splunk_image. Unset (the default) means every CR gets
  # the global image, byte-for-byte what it was before.
  # ⚠ EVERY value here must ride the ECR pull-through cache. local.splunk_image
  # (main.tf) already carries that prefix, but a sok_splunk_image_by_role entry is
  # a BARE reference like "splunk/splunk:9.4.1". Resolving the lookup chain
  # against local.splunk_image and using the result verbatim meant an OVERRIDE
  # bypassed the cache and pulled straight from Docker Hub, which fails in an
  # account without direct Docker Hub egress, so the per-role staging only
  # worked for roles left on the default.
  #
  # Resolve to a bare ref first, then apply the prefix in ONE place, mirroring
  # main.tf's local.splunk_image so the two cannot drift.
  splunk_image_ref_for = merge(
    { for role in ["lm", "mc", "cm", "idxc"] : role =>
      lookup(var.sok_splunk_image_by_role, role, var.sok_splunk_image)
    },
    { for k in keys(local.sites) : "idxc-${k}" =>
      lookup(var.sok_splunk_image_by_role, "idxc-${k}",
      lookup(var.sok_splunk_image_by_role, "idxc", var.sok_splunk_image))
    },
    { for k in keys(local.sh_map) : "sh-${k}" =>
      lookup(var.sok_splunk_image_by_role, "sh-${k}",
      lookup(var.sok_splunk_image_by_role, "sh", var.sok_splunk_image))
    },
    { for k in keys(local.shc_map) : "shc-${k}" =>
      lookup(var.sok_splunk_image_by_role, "shc-${k}",
      lookup(var.sok_splunk_image_by_role, "shc", var.sok_splunk_image))
    },
  )

  image_for = { for role, ref in local.splunk_image_ref_for : role =>
    local.ecr_cache ? "${local.ecr_registry}/docker-public/${trimprefix(ref, "docker.io/")}" : ref
  }

  # Replaces the old single cr_common. resources stays global on purpose: making
  # it per-role too is the same one-line shape, but changing a CR's requests or
  # limits also changes its QoS class, so it wants its own decision rather than
  # riding along with an image bump.
  cr_common_for = { for role, img in local.image_for : role => {
    image     = img
    resources = local.resources
  } }

  # Multisite (prod): one IndexerCluster CR per site, each pinned to its AZ; the
  # CM sits in site1's AZ. Empty for single-site (dev), a single idxc + a
  # Standalone SH instead.
  #
  # Derived from var.available_sites (comma-delimited "site1,site2,...") and
  # data.aws_availability_zones.available so the mapping is driven by real AWS
  # data rather than a hardcoded letter list. AWS returns AZs sorted, so
  # index 0 = <region>a, 1 = <region>b, 2 = <region>c, etc.
  # site1 → names[0], site2 → names[1], site3 → names[2], …
  sites = var.multisite ? {
    for site in toset(split(",", var.available_sites)) :
    trimspace(site) => data.aws_availability_zones.available.names[tonumber(trimspace(trimprefix(trimspace(site), "site"))) - 1]
  } : {}

  # Indexers don't serve the web UI. Disabling splunkweb removes the "Waiting
  # for web server at :8000" step from `splunk start`, which was TIMING OUT on
  # the multisite peers (KV-store-upgrade 60s delay + SmartStore S3 init stack
  # up, so splunkweb bound too late), failing ansible's "Start Splunk via CLI"
  # after 5 retries -> exitCode 2 -> pod crashloop, peers never registering with
  # the CM. splunkd's mgmt port is up regardless; the UI is served by the SHC.
  # (String "0" so the ini writer emits a bare 0.)
  # A multisite SEARCH HEAD needs BOTH [general] site AND [clustering] multisite
  # = true (site0 = a search-head-only value meaning "no search affinity"). Splunk
  # docs, "Configure multisite indexer clusters with server.conf". Without the
  # multisite key the CM refuses it.
  #
  # ⚠ Do NOT try to write those keys declaratively via spec.defaults `conf:`.
  # splunk-ansible's splunk_common/tasks/peer_cluster_master.yml runs
  # `splunk edit cluster-config -mode searchhead -master_uri … -replication_port
  # … -secret …` with NO -multisite flag, which rewrites the whole [clustering]
  # stanza and puts multisite back to false on EVERY pod start. A server.conf
  # override is silently undone. (Verified against splunk-ansible; this is why
  # the indexer trick below does not transfer to the search tier.)
  #
  # splunk_search_head/tasks/main.yml gates the two paths mutually exclusively:
  #   peer_cluster_master.yml  when: splunk_indexer_cluster and
  #                                  splunk.multisite_master is NOT defined
  #   setup_multisite.yml      when: splunk.site and splunk.multisite_master
  #                                  are BOTH defined
  # so setting multisite_master is the ONLY supported route: it suppresses the
  # single-site task and instead runs `edit cluster-config -mode searchhead …`
  # followed by `edit cluster-master … -site site0 -multisite True`, which writes
  # both keys in the right order. Matches docs/kubernetes-sok.md's SHC shape.
  #
  # ⚠ SHC ONLY, and this is a TOOLING limit, not a Splunk one. Splunk documents a
  # standalone (non-SHC) multisite search head as a supported config: [general]
  # site + [clustering] multisite/manager_uri/mode ("Configure multisite indexer
  # clusters with server.conf"). splunk-ansible just has no route to it:
  # splunk_standalone/tasks/main.yml includes peer_cluster_master.yml under the
  # same "multisite_master is not defined" gate but has NO setup_multisite.yml,
  # so multisite_master suppresses the only task that joins the SH to the CM and
  # replaces it with nothing. Writing [clustering] declaratively instead does not
  # work either (peer_cluster_master.yml runs after the conf overrides and rewrites
  # the stanza), and suppressing it leaves nothing to supply the clustering
  # pass4SymmKey. The guard below therefore blocks the combination.
  #
  # ⚠ Tied to the ClusterManager CR being named "cm" (this file). Named once here
  # so the SHC defaults, the standalone-SH post playbook (configmaps.tf) and any
  # future consumer cannot drift apart.
  cm_service_name = "splunk-cm-cluster-manager-service"

  # site0 = the search-head-only value meaning "no search affinity".
  sh_multisite_site = "site0"

  shc_multisite_defaults = var.multisite ? {
    site             = local.sh_multisite_site
    multisite_master = local.cm_service_name
  } : {}

  # Applied to EVERY CR's defaults blob.
  #
  # splunk-ansible seeds the admin password from user-seed.conf ONLY when
  # first_run is true (splunk_common/tasks/enable_admin_auth.yml). On every later
  # start it re-asserts it only when splunk.declarative_admin_password is true,
  # and inventory/splunk_defaults_linux.yml defaults that to False. So a pod whose
  # etc PVC survives from an earlier build keeps whatever password it was first
  # built with, while ansible reads the CORRECT one from the mounted secret and
  # authenticates every subsequent task with it. Every one of those tasks then
  # fails.
  #
  # The visible cost is "Set node as license slave", which runs
  # `edit licenser-localslave … -auth admin:{{ splunk.password }}` with
  # retry_num (60) x retry_delay (6s) ~= 450s of retries, on EVERY pod, EVERY
  # start. It carries `ignore_errors: yes` and a `failed_when` narrowed to one
  # unrelated stderr string, so it never aborts the run: the pod simply comes up
  # ~7.5 minutes late AND unlicensed.
  #
  # ⚠ NESTING IS NOT UNIFORM in splunk-ansible's defaults. declarative_admin_password
  # sits UNDER `splunk:`; retry_num / retry_delay / hide_password are TOP-LEVEL.
  # Everything here is under `splunk:`, so only the former belongs in this map.
  common_splunk_defaults = {
    declarative_admin_password = true
  }

  # LM / MC / CM: the common keys plus the ALB proxy web.conf when the ALB is on.
  # Replaces the old local.web_proxy_defaults, which carried only the proxy conf
  # and vanished entirely ({}) when the ALB was off, taking the common keys with
  # it. Always non-empty now, because common_splunk_defaults always applies.
  cr_defaults = {
    defaults = yamlencode({
      splunk = merge(
        local.common_splunk_defaults,
        local.web_external_enabled ? { conf = concat(local.web_proxy_conf, [local.overlay_app_conf]) } : {}
      )
    })
  }

  # ONE defaults blob per SHC: the common keys, the multisite keys and the ALB
  # proxy web.conf must ride together, two `defaults` merge args would clobber
  # each other (later wins).
  shc_defaults = {
    defaults = yamlencode({
      splunk = merge(
        local.common_splunk_defaults,
        local.shc_multisite_defaults,
        local.web_external_enabled ? { conf = concat(local.web_proxy_conf, [local.overlay_app_conf]) } : {}
      )
    })
  }

  # Standalone-SH multisite, via SPLUNK_ANSIBLE_POST_TASKS.
  #
  # REPLACES an earlier attempt that wrote a [clustermaster:cm] stanza through
  # spec.defaults `conf:`. That was abandoned, not merely improved on: the stanza
  # is the MULTI-cluster search-head form, selected by
  # [clustering] master_uri = clustermaster:<label>, and peer_cluster_master.yml
  # writes master_uri = <url> instead, so it was probably inert. Running both at
  # once would also give Splunk a direct master_uri AND a clustermaster stanza,
  # which is a conflict rather than a belt-and-braces.
  #
  # Why POST_TASKS is the right hook, and the only one that is:
  #   - spec.defaults `conf:` is undone. peer_cluster_master.yml rewrites the
  #     whole [clustering] stanza on every start (see shc_multisite_defaults).
  #   - SPLUNK_BEFORE_START_CMD runs before splunkd starts, which is INSIDE
  #     site.yml, so peer_cluster_master.yml still runs after it.
  #   - SPLUNK_ANSIBLE_POST_TASKS runs after site.yml COMPLETES (splunk-ansible
  #     docs/ADVANCED.md). Nothing in the operator's provisioning follows it.
  #
  # What it runs: splunk_search_head's own setup_multisite.yml, the vendor code
  # path splunk_standalone omits. That task does
  #   edit cluster-config -mode searchhead -master_uri <uri> -secret <idxc key>
  #   edit cluster-master  -old_master_uri <uri> -site <site> -multisite True
  # so the clustering pass4SymmKey is supplied properly, which the abandoned
  # approach could not do without leaking the key into the CR body.
  #
  # The vars it needs (splunk.site, splunk.multisite_master) are set INSIDE the
  # post playbook, deliberately NOT in spec.defaults: defining multisite_master
  # up front makes splunk_standalone skip peer_cluster_master.yml, the only task
  # that peers the SH to the CM at all, and it has no setup_multisite.yml to run
  # instead. Setting them after site.yml gets both: normal peering first, then
  # multisite layered on.
  #
  # ⚠ UNTESTED on a live pod. Verify with
  #   splunk list cluster-config | grep -i 'multisite\|mode\|master_uri'
  #
  # ⚠ Tied to the ClusterManager CR being named "cm" (this file).
  sh_multisite_enabled = var.multisite && var.sok_allow_multisite_standalone_sh && length(local.sh_map) > 0

  # SPLUNK_ANSIBLE_POST_TASKS points at OUR two-task list (configmaps.tf), which
  # include_role's the vendor's setup_multisite.yml. It cannot point at the vendor
  # file directly: execute_adhoc_plays.yml FETCHES the target into
  # /opt/container_artifact/ before including it, so that file's own relative
  # includes (../../../roles/splunk_common/tasks/...) resolve against the staging
  # dir and fail with "Could not find or access '/roles/splunk_common/tasks/
  # wait_for_splunk_instance.yml'". include_role resolves through the roles path
  # instead, and the task file then runs from its real location.
  #
  # merge-of-single-key-conditionals, NOT one ternary over a two-key object. HCL
  # unifies the branch types, and extraEnv (list of {name,value}) cannot unify
  # with volumes (list of {name,configMap}) into the single element type a map
  # requires. Same trap as cm_affinity below and the sh_map/shc_map note above.
  sh_multisite_env = merge(
    local.sh_multisite_enabled ? {
      extraEnv = [{ name = "SPLUNK_ANSIBLE_POST_TASKS", value = "file:///mnt/multisite/post.yml" }]
    } : {},
    local.sh_multisite_enabled ? {
      volumes = [{
        name      = "multisite"
        configMap = { name = one(kubernetes_config_map_v1.sh_multisite_post[*].metadata[0].name) }
      }]
    } : {},
  )

  # setup_multisite.yml reads splunk.site and splunk.multisite_master, so unlike
  # the earlier design these DO go in spec.defaults. The reason that was avoided
  # (defining multisite_master makes splunk_standalone skip peer_cluster_master.yml,
  # the only task that peers the SH to the CM) stops mattering here: the post task
  # runs `edit cluster-config -mode searchhead -master_uri … -secret …` itself, so
  # it does the peering AND the multisite, and nothing writes multisite = false in
  # between.
  #
  # ⚠ TRADE-OFF: because peer_cluster_master.yml is now suppressed, a post task
  # that FAILS leaves the SH not peered at all, rather than peered single-site.
  # This fails hard, not safe. Check `splunk list cluster-config` after any change.
  sh_multisite_defaults = local.sh_multisite_enabled ? {
    site             = local.sh_multisite_site
    multisite_master = local.cm_service_name
  } : {}

  # ONE defaults blob per standalone SH, for exactly the reason the SHC needs
  # one: `defaults` is a single key, so passing a proxy-conf map AND a second map
  # carrying `defaults` to merge() silently drops the first (later wins). That is
  # what knocked out the ALB proxy web.conf on the SHs.
  sh_defaults = {
    defaults = yamlencode({
      splunk = merge(
        local.common_splunk_defaults,
        local.sh_multisite_defaults,
        local.web_external_enabled ? { conf = concat(local.web_proxy_conf, [local.overlay_app_conf]) } : {}
      )
    })
  }

  # ⚠ NEVER point a spec.defaults `conf:` entry at /opt/splunk/etc/system/local.
  #
  # splunk-ansible's set_config_file.yml runs "Remove stale <file> before writing
  # config map values" and REMOVES the whole target file before writing the
  # stanzas. Aimed at system/local/server.conf that destroys what splunk-ansible
  # itself wrote there minutes earlier, most importantly [general] pass4SymmKey
  # (set_general_symmkey_password.yml). Splunk then falls back to the packaged
  # default in system/default/server.conf, which is literally `changeme`, and you
  # get: LM "Signature mismatch between license peer and this License Manager",
  # indexer_discovery HMAC failures against the pod's OWN localhost:8089, and
  # "Set node as license slave" burning all 60 retries (~450s) on every pod.
  # Observed directly in a pod's ansible log: "Set general pass4SymmKey / changed"
  # at 11:44:56, then TWO "Remove stale server.conf ... / changed" at 11:45:17 and
  # 11:45:22, after which [general] pass4SymmKey decoded to changeme.
  #
  # It is also destructive BETWEEN our own entries: two entries naming the same
  # conf file and directory means the second removes what the first just wrote.
  #
  # So everything that would have gone to system/local goes into ONE app instead.
  # App-layer values still win over system/default, which is all these need, and
  # removing a file inside our own app harms nothing. Same trick the SmartStore
  # overlay already uses (configmaps.tf, manager-apps/...). 000_ prefix so it
  # sorts first.
  overlay_app     = "/opt/splunk/etc/apps/000_sok_overlay"
  overlay_app_dir = "${local.overlay_app}/local"

  # Companion app.conf. Include EXACTLY ONCE per CR's conf list.
  overlay_app_conf = {
    key = "app"
    value = {
      directory = "${local.overlay_app}/default"
      content = {
        install = { state = "enabled" }
        package = { check_for_updates = "false" }
        ui      = { is_visible = "false" }
      }
    }
  }

  indexer_conf_overrides = [
    {
      key = "web"
      value = {
        directory = local.overlay_app_dir
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
  # Zone-only affinity for CM — never includes the indexer role expression so CM
  # can schedule on general nodes even when sok_indexer_node_role is set.
  # affinity_for_zone ANDs the role constraint in; reusing it here would make CM
  # require splunk-sok/role=indexer, which it can never satisfy (NoSchedule taint).
  cm_affinity_for_zone = {
    nodeAffinity = {
      requiredDuringSchedulingIgnoredDuringExecution = {
        nodeSelectorTerms = [{
          matchExpressions = [{
            key      = "topology.kubernetes.io/zone"
            operator = "In"
            values   = [local.cm_az]
          }]
        }]
      }
    }
  }

  # merge-of-conditionals, NOT a ternary of differently-shaped objects, HCL
  # ternaries require type-unifiable branches (same trap as the SHC defaults).
  # Always pin CM to its storage AZ (multisite: site1; single-site: general-a).
  # Without this the pod can land on any node and then be stuck waiting for a
  # cross-AZ EBS volume that Kubernetes will never allow to attach.
  cm_affinity = merge(local.cm_anti_indexer, local.cm_affinity_for_zone)

  # requiredDuringScheduling nodeAffinity onto a specific AZ, precomputed per AZ.
  # When sok_indexer_node_role is set the role matchExpression rides in the SAME
  # nodeSelectorTerm so both constraints are ANDed. Two separate terms would be
  # ORed, silently dropping one constraint — and merge() over two nodeAffinity
  # objects clobbers the first entirely.
  # Derived from local.sites values so new sites are covered automatically.
  affinity_for_zone = { for z in values(local.sites) : z => {
    nodeAffinity = {
      requiredDuringSchedulingIgnoredDuringExecution = {
        nodeSelectorTerms = [{
          matchExpressions = concat(
            [{
              key      = "topology.kubernetes.io/zone"
              operator = "In"
              values   = [z]
            }],
            var.sok_indexer_node_role != "" ? [{
              key      = "splunk-sok/role"
              operator = "In"
              values   = [var.sok_indexer_node_role]
            }] : []
          )
        }]
      }
    }
  } }

  # Toleration for the indexer dedicated node group taint (NoSchedule).
  # Empty when sok_indexer_node_role is unset — CM/SH/LM/MC/operator pods have no
  # toleration and are therefore excluded from role-tainted nodes automatically.
  indexer_tolerations = var.sok_indexer_node_role != "" ? [
    {
      key      = "splunk-sok/role"
      operator = "Equal"
      value    = var.sok_indexer_node_role
      effect   = "NoSchedule"
    }
  ] : []
}

# Standalone SHs cannot join a multisite cluster: splunk_standalone/tasks/main.yml
# includes peer_cluster_master.yml under "splunk.multisite_master is not defined"
# but ships no setup_multisite.yml, so there is no combination of spec.defaults
# that both peers the SH to the CM and marks it multisite. Left alone it peers
# with multisite=false; with multisite_master set it never peers at all. Splunk
# ITSELF supports a standalone multisite search head, splunk-ansible has no path
# to configure one (see the shc_multisite_defaults note), so this is a SOK limit.
# Fail the plan rather than build a search head that silently never joins. Use a
# SearchHeadCluster on multisite (dev-multisite.tfvars already sets
# sok_standalone_search_heads = {}); a 1-member SHC is legal and pdb.tf already
# skips the PDB for it.
#
# sok_allow_multisite_standalone_sh = true opts past this by turning ON the
# SPLUNK_ANSIBLE_POST_TASKS route (see local.sh_multisite_enabled), which runs
# splunk_search_head's own setup_multisite.yml after site.yml has finished.
#
# The condition deliberately tests local.sh_multisite_enabled rather than the
# variable directly. They are logically equivalent here (when multisite and
# standalone SHs are both present, sh_multisite_enabled reduces to the variable),
# but going through the local means the guard cannot pass unless the post-task
# ConfigMap and extraEnv are actually being created. One expression, one truth.
#
# Still UNVERIFIED on a live pod. If `splunk list cluster-config` on the SH
# reports multisite=false after this, the post task did not take and the
# supported answer is a 1-member SearchHeadCluster.
resource "terraform_data" "search_tier_guard" {
  input = keys(local.sh_map)

  lifecycle {
    precondition {
      condition     = !(var.multisite && length(local.sh_map) > 0) || local.sh_multisite_enabled
      error_message = "multisite = true with standalone search heads (${join(", ", sort(keys(local.sh_map)))}): Splunk supports a standalone multisite search head, but splunk-ansible does not configure one (splunk_standalone has no setup_multisite.yml, and peer_cluster_master.yml never sets multisite), so these CRs would peer as single-site or not at all. Move them to sok_search_head_clusters, or clear sok_standalone_search_heads on the multisite overlay. To use the SPLUNK_ANSIBLE_POST_TASKS route instead (it runs splunk_search_head/tasks/setup_multisite.yml after site.yml, which is the only point nothing rewrites [clustering] afterwards), set sok_allow_multisite_standalone_sh = true, then VERIFY with `splunk list cluster-config` on the SH pod: it is not proven yet. If you are seeing this unexpectedly, check the -var-file ORDER: vars/<env>.tfvars must come BEFORE vars/overlays/<name>.tfvars."
    }
  }
}

# A key that matches no role is silently ignored by lookup(), so a typo like
# "licensemanager" or "sh_sm" would leave that CR on the old image while the
# apply reports success. Fail the plan instead.
resource "terraform_data" "image_role_guard" {
  input = sort(keys(var.sok_splunk_image_by_role))

  lifecycle {
    precondition {
      condition = length(setsubtract(
        keys(var.sok_splunk_image_by_role),
        concat(keys(local.image_for), ["sh", "shc"])
      )) == 0
      error_message = "sok_splunk_image_by_role has unknown role key(s): ${join(", ", sort(setsubtract(keys(var.sok_splunk_image_by_role), concat(keys(local.image_for), ["sh", "shc"]))))}. Valid keys for THIS shape: ${join(", ", sort(concat(keys(local.image_for), ["sh", "shc"])))}."
    }
  }
}

resource "kubectl_manifest" "license_manager" {
  yaml_body = yamlencode({
    apiVersion = "enterprise.splunk.com/v4"
    kind       = "LicenseManager"
    metadata   = { name = "lm", namespace = local.namespace }
    # cr_defaults: declarative_admin_password + ALB-fronted UI redirects.
    spec = merge(local.cr_common_for["lm"], local.storage_for["lm"], local.probes, local.cr_defaults, {
      # CR volumes are mounted at /mnt/<name> in the Splunk pod.
      # Native SOK 3.2.0 cert management. [] unless sok_private_ca_enabled (certs.tf).
      certs      = local.tls_certs_for["lm"]
      licenseUrl = "/mnt/licenses/enterprise.lic"
      volumes = [
        { name = "licenses", secret = { secretName = kubernetes_secret_v1.license.metadata[0].name } }
      ]
      monitoringConsoleRef = { name = "mc" }
      clusterManagerRef    = { name = "cm" }
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
    # cr_defaults: declarative_admin_password + ALB-fronted UI redirects.
    spec = merge(local.cr_common_for["mc"], local.storage_for["mc"], local.probes, local.cr_defaults, {
      # Native SOK 3.2.0 cert management. [] unless sok_private_ca_enabled (certs.tf).
      certs             = local.tls_certs_for["mc"]
      licenseManagerRef = { name = "lm" }
      # Required when multisite=true: without this the operator injects
      # SPLUNK_MULTISITE_MASTER into the MC pod, which triggers the ansible
      # splunk_monitor role to run `edit cluster-config -mode searchhead` —
      # the CM rejects this (rc=22) causing the startup probe to fail and the
      # pod to crash-loop indefinitely.
      clusterManagerRef = var.multisite ? { name = "cm" } : {}

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
    # cr_defaults (declarative_admin_password + ALB UI redirects) rides inline
    # `defaults` and coexists with defaultsUrl, splunk-ansible merges both at
    # key level, so the CM's mounted defaults overlay is unaffected.
    # cm_affinity: zone pin (multisite) + SOFT anti-affinity away from indexer
    # pods, Anderson saw CM/indexer co-location fail ungracefully under load.
    # preferred (not required) so the single-node dev shape still schedules.
    spec = merge(local.cr_common_for["cm"], local.storage_for["cm"], local.cm_probes, { affinity = local.cm_affinity }, local.cr_defaults, {
      serviceAccount       = kubernetes_service_account_v1.splunk_idx.metadata[0].name
      licenseManagerRef    = { name = "lm" }
      monitoringConsoleRef = { name = "mc" }

      # Native SOK 3.2.0 cert management. [] unless sok_private_ca_enabled (certs.tf).
      certs       = local.tls_certs_for["cm"]
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
    spec = merge(
      local.cr_common_for["idxc"],
      local.storage_for["idxc"],
      local.probes,
      # Role-only affinity (no zone pin on single-site): attracts indexers to the
      # dedicated node group when sok_indexer_node_role is set. No-op when empty.
      var.sok_indexer_node_role != "" ? {
        affinity = {
          nodeAffinity = {
            requiredDuringSchedulingIgnoredDuringExecution = {
              nodeSelectorTerms = [{
                matchExpressions = [{
                  key      = "splunk-sok/role"
                  operator = "In"
                  values   = [var.sok_indexer_node_role]
                }]
              }]
            }
          }
        }
      } : {},
      length(local.indexer_tolerations) > 0 ? { tolerations = local.indexer_tolerations } : {},
      {
        # Native SOK 3.2.0 cert management. [] unless sok_private_ca_enabled (certs.tf).
        certs                = local.tls_certs_for["idxc"]
        replicas             = var.sok_indexer_replicas
        serviceAccount       = kubernetes_service_account_v1.splunk_idx.metadata[0].name
        clusterManagerRef    = { name = "cm" }
        licenseManagerRef    = { name = "lm" }
        monitoringConsoleRef = { name = "mc" }
        # Indexers don't serve the UI, disable splunkweb (see indexer_conf_overrides).
        defaults = yamlencode({
          splunk = merge(local.common_splunk_defaults, { conf = concat(local.indexer_conf_overrides, [local.overlay_app_conf]) })
        })
      }
    )
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
    spec = merge(
      local.cr_common_for["idxc-${each.key}"],
      local.storage_for["idxc"],
      local.probes,
      length(local.indexer_tolerations) > 0 ? { tolerations = local.indexer_tolerations } : {},
      {
        replicas             = var.sok_indexer_replicas
        serviceAccount       = kubernetes_service_account_v1.splunk_idx.metadata[0].name
        clusterManagerRef    = { name = "cm" }
        licenseManagerRef    = { name = "lm" }
        monitoringConsoleRef = { name = "mc" }
        # Native SOK 3.2.0 cert management. [] unless sok_private_ca_enabled (certs.tf).
        certs    = local.tls_certs_for["idxc-${each.key}"]
        affinity = local.affinity_for_zone[each.value]
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
          splunk = merge(local.common_splunk_defaults, {
            site = each.key
            conf = concat(local.indexer_conf_overrides, [
              {
                key = "server"
                value = {
                  directory = local.overlay_app_dir
                  content   = { general = { site = each.key } }
                }
              },
              local.overlay_app_conf,
            ])
          })
        })
    })
  })

  depends_on = [kubectl_manifest.cluster_manager]
}

# Standalone search heads — one CR per entry in local.sh_map.
# CR name: sh-<key> (e.g. sh-default, sh-analyst).
# App S3 prefix: entry.app_location if set, otherwise "sh-<key>-apps/"
# (the legacy single-SH fallback uses "sh-apps/" via the "default" key
# mapped to {}, which evaluates to "sh-default-apps/"; set app_location
# = "sh-apps/" explicitly in the map entry to restore the old prefix).
resource "kubectl_manifest" "search_head" {
  for_each = local.sh_map

  yaml_body = yamlencode({
    apiVersion = "enterprise.splunk.com/v4"
    kind       = "Standalone"
    metadata   = { name = "sh-${each.key}", namespace = local.namespace }
    # sh_defaults, NOT web_proxy_defaults + a second `defaults` arg: both occupy
    # the same key and the later one wins, which is how the ALB proxy web.conf
    # got dropped. NOT the SHC's multisite_master either — splunk_standalone has
    # no setup_multisite.yml, so that would only suppress the task that peers it
    # to the CM. See the sh_multisite_conf note for what is attempted instead,
    # and terraform_data.search_tier_guard below for when it is permitted.
    spec = merge(local.cr_common_for["sh-${each.key}"], local.storage_for["sh-${each.key}"], local.probes, local.sh_defaults, local.sh_multisite_env, {
      # Native SOK 3.2.0 cert management. [] unless sok_private_ca_enabled (certs.tf).
      certs                = local.tls_certs_for["sh-${each.key}"]
      clusterManagerRef    = { name = "cm" }
      licenseManagerRef    = { name = "lm" }
      monitoringConsoleRef = { name = "mc" }

      appRepo = {
        appsRepoPollIntervalSeconds = 600
        defaults                    = { volumeName = "appvol", scope = "local" }
        volumes                     = [local.appframework_volume]
        appSources = [
          {
            name     = "sh-${each.key}-apps"
            location = each.value.app_location
            scope    = "local"
          },
        ]
      }
    })
  })

  depends_on = [kubectl_manifest.cluster_manager]
}

# Search Head Clusters — one CR per entry in local.shc_map.
# CR name: shc-<key> (e.g. shc-default). The operator creates a deployer pod
# named splunk-shc-<key>-deployer-0. The KV-store backup (kvbackup.tf) targets
# ALL SHCs when enabled.
# App S3 prefix: entry.app_location if set, otherwise "shc-<key>-apps/".
# Replicas: entry.replicas if set, otherwise 3.
resource "kubectl_manifest" "search_head_cluster" {
  for_each = local.shc_map

  yaml_body = yamlencode({
    apiVersion = "enterprise.splunk.com/v4"
    kind       = "SearchHeadCluster"
    metadata   = { name = "shc-${each.key}", namespace = local.namespace }
    spec = merge(local.cr_common_for["shc-${each.key}"], local.storage_for["shc-${each.key}"], local.probes,
      # shc_defaults: site0 + multisite_master + the ALB proxy web.conf, in ONE
      # blob (see the note on local.shc_multisite_defaults). The operator applies
      # SHC-CR defaults to the deployer pods too, so an exposed deployer UI gets
      # the proxy conf for free.
      local.shc_defaults,
      # Spread SHC members across AZs so a single-AZ loss never takes the SHC/KV
      # majority (NFR-3). ScheduleAnyway is best-effort (no bring-up deadlock).
      var.multisite ? {
        topologySpreadConstraints = [{
          maxSkew           = 1
          topologyKey       = "topology.kubernetes.io/zone"
          whenUnsatisfiable = "ScheduleAnyway"
          labelSelector     = { matchLabels = { "app.kubernetes.io/instance" = "splunk-shc-${each.key}-search-head" } }
        }]
      } : {},
      {
        # Number-typed by local.shc_map (see the type-unification note there):
        # the CRD's spec.replicas is int32 and rejects a quoted "3".
        # Native SOK 3.2.0 cert management. [] unless sok_private_ca_enabled (certs.tf).
        certs                = local.tls_certs_for["shc-${each.key}"]
        replicas             = each.value.replicas
        clusterManagerRef    = { name = "cm" }
        licenseManagerRef    = { name = "lm" }
        monitoringConsoleRef = { name = "mc" }

        # scope MUST be "cluster", not "local". On a SearchHeadCluster CR the two
        # scopes land in different places (SOK AppFramework.md, and the CRD's own
        # enum: cluster | clusterWithPreConfig | local | premiumApps):
        #   local   -> $SPLUNK_HOME/etc/apps on the DEPLOYER ONLY. The members
        #              never see the app; nothing is ever pushed.
        #   cluster -> $SPLUNK_HOME/etc/shcluster/apps on the deployer, which the
        #              operator then pushes to every member's etc/apps.
        # This was "local" and silently installed every SHC app on the deployer
        # and nowhere else, which looks like a working deploy until you search.
        # The S3 prefix is unchanged, only the scope.
        appRepo = {
          appsRepoPollIntervalSeconds = 600
          defaults                    = { volumeName = "appvol", scope = "cluster" }
          volumes                     = [local.appframework_volume]
          appSources = [
            {
              name     = "shc-${each.key}-apps"
              location = each.value.app_location
              scope    = "cluster"
            },
          ]
        }
    })
  })

  depends_on = [kubectl_manifest.cluster_manager]
}