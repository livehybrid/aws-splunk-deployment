###############################################################################
# defaultsUrl ConfigMaps.
#
# NEVER use inline spec.defaults for anything that might be edited, every
# inline edit triggers a full rolling recycle of that CR's pods. A ConfigMap
# mounted via spec.volumes (operator mounts each volume at /mnt/<name>) and
# referenced by spec.defaultsUrl lets config changes be staged and pods
# rolled deliberately.
#
# The ClusterManager defaults carry the SSE-KMS + verified-TLS SmartStore
# overlay (spike S1a): the CR's smartstore block cannot express
# remote.s3.encryption / kms.key_id / sslVerifyServerCert / sslRootCAPath,
# so splunk-ansible's `conf` key writes them into a manager-app that rides
# the cluster bundle to every peer, layered over the operator-generated
# volume stanza (same volume name: remote_store).
#   - remote.s3.kms.key_id: dot form, the underscore form is silently ignored.
#   - CA bundle path is the UBI9 in-container OS trust store.
#   - values are strings so the ini writer emits lowercase true.
###############################################################################

locals {
  smartstore_overlay = {
    "remote.s3.encryption"              = "sse-kms"
    "remote.s3.kms.key_id"              = data.aws_kms_alias.smartstore.target_key_arn
    "remote.s3.kms.auth_region"         = var.region
    "remote.s3.sslVerifyServerCert"     = "true"
    "remote.s3.sslRootCAPath"           = "/etc/pki/tls/certs/ca-bundle.crt"
    "remote.s3.kms.sslVerifyServerCert" = "true"
    "remote.s3.kms.sslRootCAPath"       = "/etc/pki/tls/certs/ca-bundle.crt"
  }

  # The SmartStore overlay manager-app (indexes.conf + app.conf), rides the
  # cluster bundle to every peer under both single-site and multisite.
  smartstore_conf = [
    {
      key = "indexes"
      value = {
        directory = "/opt/splunk/etc/manager-apps/org_sok_smartstore_overlay/local"
        content = {
          "volume:remote_store" = local.smartstore_overlay
        }
      }
    },
    {
      key = "app"
      value = {
        directory = "/opt/splunk/etc/manager-apps/org_sok_smartstore_overlay/default"
        content = {
          install = { state = "enabled" }
          package = { check_for_updates = "false" }
          ui      = { is_visible = "false" }
        }
      }
    },
  ]

  # Multisite only: server.conf [clustering] constrain_singlesite_buckets=false
  # lets legacy single-site buckets (bootstrapped from SmartStore before the
  # multisite cutover) meet RF across sites, same lesson as the EC2 rollout.
  constrain_conf = {
    key = "server"
    value = {
      # NOT system/local: writing server.conf there makes splunk-ansible remove
      # the file first, taking [general] pass4SymmKey with it. This one wiped the
      # CM's key on every multisite start. See the overlay_app note in crs.tf.
      directory = local.overlay_app_dir
      content   = { clustering = { constrain_singlesite_buckets = "false" } }
    }
  }

  # Multisite site/factor settings, merged into the CM defaults when multisite.
  # replication_factor/search_factor (idxc) stay in both modes: single-site uses
  # them as the cluster factors; multisite uses them for legacy non-site buckets.
  multisite_settings = var.multisite ? {
    site                                = "site1"
    multisite_master                    = "localhost"
    all_sites                           = var.available_sites
    multisite_replication_factor_origin = var.site_replication_factor_origin
    multisite_replication_factor_total  = var.site_replication_factor_total
    multisite_search_factor_origin      = var.site_search_factor_origin
    multisite_search_factor_total       = var.site_search_factor_total
  } : {}

  cm_defaults = {
    splunk = merge(local.multisite_settings, {
      idxc = {
        replication_factor = var.replication_factor
        search_factor      = var.search_factor
      }
      conf = var.multisite ? concat(local.smartstore_conf, [local.constrain_conf, local.overlay_app_conf]) : local.smartstore_conf
    })
  }
}

resource "kubernetes_config_map_v1" "cm_defaults" {
  metadata {
    name      = "splunk-cm-defaults"
    namespace = local.namespace
  }

  data = {
    "default.yml" = yamlencode(local.cm_defaults)
  }

  depends_on = [kubernetes_namespace_v1.splunk]
}

###############################################################################
# SPLUNK_ANSIBLE_POST_TASKS task list for standalone multisite search heads.
#
# A FLAT LIST OF TASKS, not a playbook. site.yml consumes ansible_post_tasks with
# `include_tasks: execute_adhoc_plays.yml` in a loop, so this is included INTO
# the running play. A play wrapper (hosts/connection/gather_facts) makes ansible
# read those play keywords as task parameters and fail with:
#   ERROR! unexpected parameter type in action: <class 'bool'>
#
# WHY THIS EXISTS AT ALL, rather than pointing SPLUNK_ANSIBLE_POST_TASKS straight
# at /opt/ansible/roles/splunk_search_head/tasks/setup_multisite.yml: that was
# tried and fails. execute_adhoc_plays.yml has a "Fetch adhoc playbooks" step
# that COPIES the target into /opt/container_artifact/ and includes it from
# there, so setup_multisite.yml's own relative includes
# (../../../roles/splunk_common/tasks/wait_for_splunk_instance.yml) resolve
# against the staging dir and land on /roles/..., which does not exist:
#   ERROR! Could not find or access '/roles/splunk_common/tasks/wait_for_splunk_instance.yml'
#
# include_role does not have that problem. It resolves through the roles path,
# and the task file then executes from its REAL location, so its relative
# includes resolve correctly. Nothing is vendored: this calls the vendor's file.
#
# splunk.site and splunk.multisite_master come from spec.defaults
# (local.sh_multisite_defaults in crs.tf), so no set_fact is needed here.
#
# IDEMPOTENCE: post tasks run on EVERY pod start and setup_multisite notifies a
# restart handler, so the btool probe skips it once [clustering] already reads
# multisite = true. The config persists on the etc PVC, so skipping is correct.
###############################################################################

resource "kubernetes_config_map_v1" "sh_multisite_post" {
  count = local.sh_multisite_enabled ? 1 : 0

  metadata {
    name      = "splunk-sh-multisite-post"
    namespace = local.namespace
  }

  data = {
    "post.yml" = yamlencode([
      {
        name         = "Read the current [clustering] stanza"
        command      = "{{ splunk.exec }} btool server list clustering"
        register     = "sh_multisite_state"
        changed_when = false
        failed_when  = false
      },
      {
        name = "Run splunk_search_head's setup_multisite (splunk_standalone ships none)"
        include_role = {
          name       = "splunk_search_head"
          tasks_from = "setup_multisite"
        }
        when = "'multisite = true' not in (sh_multisite_state.stdout | default('') | lower)"
      },
    ])
  }

  depends_on = [kubernetes_namespace_v1.splunk]
}