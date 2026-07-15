[general]
pass4SymmKey = ${pass4SymmKey}
%{ if multisite ~}
# site0: indexer discovery returns peers from every site (no affinity).
site = site0
%{ endif ~}

[sslConfig]
enableSplunkdSSL = true
sslVerifyServerCert = ${ssl_verify}
serverCert       = /opt/splunk/etc/auth/customcerts/server_combined.pem

[license]
manager_uri  = https://license.${internal_domain}:${license_port}
active_group = Forwarder

[kvstore]
serverCert  = /opt/splunk/etc/auth/customcerts/server_combined.pem
caCertFile  = $SPLUNK_HOME/etc/auth/cacert.pem
sslPassword = none
