[clustering]
mode         = searchhead
manager_uri  = https://manager.${internal_domain}:${master_port}
pass4SymmKey = ${pass4SymmKey}
%{ if multisite ~}
multisite    = true
%{ endif ~}

[general]
pass4SymmKey = ${pass4SymmKey}
%{ if multisite ~}
# site0 = no search affinity; SHs search both sites equally.
site = site0
%{ endif ~}

[replication_port://${replication_port}]

[sslConfig]
enableSplunkdSSL = true
sslVerifyServerCert = ${ssl_verify}
serverCert       = /opt/splunk/etc/auth/customcerts/server_combined.pem

[license]
manager_uri = https://license.${internal_domain}:${license_port}
