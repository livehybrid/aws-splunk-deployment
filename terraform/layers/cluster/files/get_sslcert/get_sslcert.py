#!/usr/bin/env python3
"""Issue cluster TLS certs signed by the internal CA stored in S3.

CSR identity fields are read from environment variables so the Lambda can be
re-used across deployments without code changes:

    SSL_COUNTRY   e.g. GB
    SSL_STATE     e.g. England
    SSL_CITY      e.g. London
    SSL_ORG       e.g. LiveHybrid
    SSL_ORGUNIT   e.g. Splunk
    SSL_EMAIL     e.g. splunk@livehybrid.com
"""

import datetime
import hashlib
import json
import os
import re
import subprocess

import boto3

OPENSSL_CONFIG_TEMPLATE = """
prompt = no
distinguished_name = req_distinguished_name
req_extensions = v3_req
[ req_distinguished_name ]
C                      = %(country)s
ST                     = %(state)s
L                      = %(city)s
O                      = %(org)s
OU                     = %(orgunit)s
CN                     = %(domain)s
emailAddress           = %(email)s
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names
[ alt_names ]
DNS.1 = %(domain)s
DNS.2 = *.%(domain)s
"""

MYDIR = os.path.abspath(os.path.dirname(__file__))
OPENSSL = "/opt/bin/openssl"
KEY_SIZE = 2048
DAYS = 730
CA_CERT = "ca.crt"
CA_KEY = "ca.key"

s3_conn = boto3.client("s3")
dynamodb = boto3.resource("dynamodb")
cert_table = dynamodb.Table("certificates")

crt_response = s3_conn.get_object(Bucket=os.environ["bucket"], Key=f"ca/{os.environ['ca_name']}.crt")
with open("/tmp/ca.crt", "w") as cert_file:
    cert_file.write(crt_response["Body"].read().decode("utf-8"))

key_response = s3_conn.get_object(Bucket=os.environ["bucket"], Key=f"ca/{os.environ['ca_name']}.key")
with open("/tmp/ca.key", "w") as key_file:
    key_file.write(key_response["Body"].read().decode("utf-8"))

secrets_conn = boto3.client("secretsmanager")
ca_password_secret_id = "/pki/ca-password"
ca_password = secrets_conn.get_secret_value(SecretId=ca_password_secret_id)

X509_EXTRA_ARGS = ()


def openssl(*args):
    cmdline = "RANDFILE=/tmp/.rnd " + OPENSSL + " " + " ".join(args)
    try:
        print(cmdline)
        output = subprocess.check_output(
            cmdline, stderr=subprocess.STDOUT, shell=True, timeout=30, universal_newlines=True
        )
    except subprocess.CalledProcessError as exc:
        print("Status : FAIL", exc.returncode, exc.output)
    else:
        print("Output: \n{}\n".format(output))
        return output


def _csr_config(domain):
    return OPENSSL_CONFIG_TEMPLATE % {
        "domain":  domain,
        "country": os.environ.get("SSL_COUNTRY", "GB"),
        "state":   os.environ.get("SSL_STATE", "England"),
        "city":    os.environ.get("SSL_CITY", "London"),
        "org":     os.environ.get("SSL_ORG", "LiveHybrid"),
        "orgunit": os.environ.get("SSL_ORGUNIT", "Splunk"),
        "email":   os.environ.get("SSL_EMAIL", "splunk@livehybrid.com"),
    }


def handler(event, context):
    rootdir = MYDIR
    keysize = KEY_SIZE
    days = DAYS
    ca_cert = "/tmp/" + CA_CERT
    ca_key = "/tmp/" + CA_KEY
    domain = event.get("domain", "csr_job")
    output_directory = "/tmp/"

    def dfile(ext):
        return os.path.join(output_directory, f"temp.{ext}")

    os.chdir(rootdir)
    if not os.path.exists(output_directory):
        os.mkdir(output_directory)

    if "csr" in event:
        with open(dfile("request"), "w") as csr_file:
            csr_file.write(event["csr"])

        with open(dfile("config"), "w") as config:
            config.write(_csr_config(domain))

        print(dfile("request"))
        print(event["csr"])
        print(openssl("version"))
        cert_subject = openssl("req", "-in", dfile("request"), "-noout", "-subject")
        regex = r".*\/CN=([\w\-\.]+)"
        print("subject={}".format(cert_subject))
        domain = re.findall(regex, str(cert_subject))[0]

        print("Using submitted CSR for domain={}".format(domain))

        with open(dfile("request"), "w") as csr_file:
            csr_file.write(event["csr"])

        cert_serial = "0x%s" % hashlib.md5(
            domain.encode("utf-8") + str(datetime.datetime.now()).encode("utf-8")
        ).hexdigest()

        openssl(
            "x509", "-req", "-days", str(days), "-in", dfile("request"),
            "-CA", ca_cert, "-CAkey", ca_key,
            "-passin", "pass:{}".format(ca_password["SecretString"]),
            "-set_serial", cert_serial,
            "-out", dfile("crt"),
            "-extensions", "v3_req", "-extfile", dfile("config"),
            *X509_EXTRA_ARGS,
        )

    else:
        if not os.path.exists(dfile("key")):
            openssl("genrsa", "-out", dfile("key"), str(keysize))

        with open(dfile("config"), "w") as config:
            config.write(_csr_config(domain))

        cert_serial = "0x%s" % hashlib.md5(
            domain.encode("utf-8") + str(datetime.datetime.now()).encode("utf-8")
        ).hexdigest()

        openssl(
            "req", "-new", "-key", dfile("key"), "-out", dfile("request"),
            "-config", dfile("config"),
        )

        openssl(
            "x509", "-req", "-days", str(days), "-in", dfile("request"),
            "-CA", ca_cert, "-CAkey", ca_key,
            "-passin", "pass:{}".format(ca_password["SecretString"]),
            "-set_serial", cert_serial,
            "-out", dfile("crt"),
            "-extensions", "v3_req", "-extfile", dfile("config"),
            *X509_EXTRA_ARGS,
        )

        print(
            "Done. The private key is at %s, the cert is at %s, and the CA cert is at %s."
            % (dfile("key"), dfile("crt"), ca_cert)
        )

        with open(dfile("key"), "r") as key_file:
            output_key = key_file.read()

    with open(dfile("crt"), "r") as crt_file:
        output_crt = crt_file.read()
        s3_conn.put_object(
            Bucket=os.environ["bucket"],
            Key=dfile("crt"),
            Body=output_crt,
            ServerSideEncryption="aws:kms",
            SSEKMSKeyId=os.environ["kms"],
        )

    now = datetime.datetime.now()
    cert_created_date = now.strftime("%Y-%m-%d %H:%M")
    cert_expiry_date = (now + datetime.timedelta(days=days)).strftime("%Y-%m-%d %H:%M")

    cert_table.put_item(Item={
        "serial":      cert_serial,
        "common_name": domain,
        "enabled":     1,
        "expiry":      cert_expiry_date,
        "created":     cert_created_date,
    })

    if "csr" in event:
        return json.dumps({"crt": output_crt})
    return json.dumps({"crt": output_crt, "key": output_key})
