[settings]
httpport        = ${httpport}
mgmtHostPort    = 127.0.0.1:${mgmtHostPort}
enableSplunkWebSSL = true
serverCert=/opt/splunk/etc/auth/customcerts/server.crt
privKeyPath=/opt/splunk/etc/auth/customcerts/server.key

updateCheckerBaseURL = 0
docsCheckerBaseURL = 0
enableSplunkWebSSL = 1

#UNCOMMENT THIS IF DEPLOYING A SHC
#SSOMode = permissive
#trustedIP = 127.0.0.1
#remoteUser = X-Forwarded-User
#tools.proxy.on = False
#allowSsoWithoutChangingServerConf = 1