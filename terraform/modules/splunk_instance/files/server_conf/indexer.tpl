[replication_port://${replication_port}]

[clustering]
mode         = peer
manager_uri  = https://manager.${internal_domain}:${master_port}
pass4SymmKey = ${pass4SymmKey}

[general]
pass4SymmKey = ${pass4SymmKey}
%{ if multisite ~}
site = ${site}
%{ endif ~}

[sslConfig]
enableSplunkdSSL = true
sslVerifyServerCert = ${ssl_verify}
serverCert       = /opt/splunk/etc/auth/customcerts/server_combined.pem

[license]
manager_uri = https://license.${internal_domain}:${license_port}
