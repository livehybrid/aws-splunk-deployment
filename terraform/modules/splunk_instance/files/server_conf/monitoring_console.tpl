[general]
pass4SymmKey = ${pass4SymmKey}

[sslConfig]
enableSplunkdSSL = true
sslVerifyServerCert = ${ssl_verify}
serverCert = /opt/splunk/etc/auth/customcerts/server_combined.pem

[license]
manager_uri = https://license.${internal_domain}:${license_port}

${additional_config}
