"""Internal-CA certificate issuer for Splunk cluster nodes.

Instances generate a private key + CSR locally at boot and invoke this
function with {"csr": "<PEM>"}. The CSR's CN and DNS SANs must fall under
one of ALLOWED_DNS_SUFFIXES; the signed certificate (and the CA cert for
the trust bundle) come back as {"certificate": "<PEM>", "ca": "<PEM>"}.

The CA key/cert live in the ma-certs bucket (KMS-encrypted); instances do
NOT have read access to the key object — only this function's role does.
"""

import datetime
import os

import boto3
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID

s3 = boto3.client("s3")

ALLOWED_SUFFIXES = [
    s.strip().lower()
    for s in os.environ["ALLOWED_DNS_SUFFIXES"].split(",")
    if s.strip()
]
VALIDITY_DAYS = int(os.environ.get("VALIDITY_DAYS", "730"))

_ca = None


def load_ca():
    global _ca
    if _ca is None:
        bucket = os.environ["CA_BUCKET"]
        key_pem = s3.get_object(
            Bucket=bucket, Key=os.environ["CA_KEY_OBJECT"]
        )["Body"].read()
        crt_pem = s3.get_object(
            Bucket=bucket, Key=os.environ["CA_CRT_OBJECT"]
        )["Body"].read()
        _ca = (
            serialization.load_pem_private_key(key_pem, password=None),
            x509.load_pem_x509_certificate(crt_pem),
        )
    return _ca


def name_allowed(name):
    n = name.lower()
    n = n[2:] if n.startswith("*.") else n
    return any(n == s or n.endswith("." + s) for s in ALLOWED_SUFFIXES)


def handler(event, _context):
    csr = x509.load_pem_x509_csr(event["csr"].encode())
    if not csr.is_signature_valid:
        raise ValueError("CSR signature invalid")

    cns = [
        a.value for a in csr.subject.get_attributes_for_oid(NameOID.COMMON_NAME)
    ]
    try:
        sans = csr.extensions.get_extension_for_class(
            x509.SubjectAlternativeName
        ).value.get_values_for_type(x509.DNSName)
    except x509.ExtensionNotFound:
        sans = []

    requested = cns + sans
    if not requested:
        raise ValueError("CSR contains no CN or DNS SANs")
    for name in requested:
        if not name_allowed(name):
            raise ValueError(f"requested name not permitted: {name}")

    ca_key, ca_crt = load_ca()
    now = datetime.datetime.now(datetime.timezone.utc)
    cert = (
        x509.CertificateBuilder()
        .subject_name(csr.subject)
        .issuer_name(ca_crt.subject)
        .public_key(csr.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(minutes=5))
        .not_valid_after(now + datetime.timedelta(days=VALIDITY_DAYS))
        .add_extension(
            x509.SubjectAlternativeName([x509.DNSName(n) for n in sans]),
            critical=False,
        )
        .add_extension(
            x509.BasicConstraints(ca=False, path_length=None), critical=True
        )
        .add_extension(
            x509.KeyUsage(
                digital_signature=True,
                key_encipherment=True,
                content_commitment=False,
                data_encipherment=False,
                key_agreement=False,
                key_cert_sign=False,
                crl_sign=False,
                encipher_only=False,
                decipher_only=False,
            ),
            critical=True,
        )
        .add_extension(
            x509.ExtendedKeyUsage(
                [ExtendedKeyUsageOID.SERVER_AUTH, ExtendedKeyUsageOID.CLIENT_AUTH]
            ),
            critical=False,
        )
        .add_extension(
            x509.SubjectKeyIdentifier.from_public_key(csr.public_key()),
            critical=False,
        )
        .add_extension(
            x509.AuthorityKeyIdentifier.from_issuer_public_key(
                ca_key.public_key()
            ),
            critical=False,
        )
        .sign(ca_key, hashes.SHA512())
    )

    return {
        "certificate": cert.public_bytes(serialization.Encoding.PEM).decode(),
        "ca": ca_crt.public_bytes(serialization.Encoding.PEM).decode(),
    }
