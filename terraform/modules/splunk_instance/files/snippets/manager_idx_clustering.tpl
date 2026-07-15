[indexer_discovery]
pass4SymmKey = ${pass4SymmKey}

[clustering]
mode               = manager
replication_factor = ${replication_factor}
search_factor      = ${search_factor}
pass4SymmKey       = ${pass4SymmKey}
%{ if multisite ~}
multisite               = true
available_sites         = ${available_sites}
site_replication_factor = origin:${site_replication_factor_origin},total:${site_replication_factor_total}
site_search_factor      = origin:${site_search_factor_origin},total:${site_search_factor_total}
# Legacy non-site buckets (bootstrapped from SmartStore, pre-multisite) follow
# the single-site replication_factor; constrained to one site that needs RF
# peers per site (impossible at 2/site), so let their copies span sites.
constrain_singlesite_buckets = false
%{ endif ~}
