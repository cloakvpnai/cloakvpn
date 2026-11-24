"""Certificate building for the Lattice VPN CNSA 2.0 certificate authority.

Everything is ML-DSA-87 (RFC 9881 encoding). This module assembles certificate
bodies and hands them to a signer; the signer for real use is AWS KMS, so no
private CA key is ever present here.

A certificate request is used for one thing only: the public key, after its
self-signature has been checked. Names, lifetimes and usages are decided here.
"""
import base64
import datetime
import hashlib
import os
import re
import subprocess
import tempfile

ML_DSA_87 = "2.16.840.1.101.3.4.3.19"
ORG = "Lattice VPN"
REGION = "us-west-2"
ROOT_KEY = "alias/lattice-ca-root"
ISSUING_KEY = os.environ.get("LATTICE_ISSUING_KEY", "alias/lattice-ca-issuing")
USE_BOTO3 = os.environ.get("LATTICE_KMS") == "boto3"
AWS = os.environ.get("AWS_CLI", "/opt/homebrew/bin/aws")
OPENSSL = os.environ.get("OPENSSL") or ("/opt/homebrew/bin/openssl" if os.path.exists("/opt/homebrew/bin/openssl") else "openssl")

DEVICE_DAYS = 30
GATEWAY_DAYS = 90
NAME_RE = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$")


class RequestError(ValueError):
    """The request is not acceptable. The message is safe to return to the caller."""


# ---- DER encoding -------------------------------------------------------

def length(n):
    if n < 0x80:
        return bytes([n])
    b = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return bytes([0x80 | len(b)]) + b


def tlv(tag, body):
    return bytes([tag]) + length(len(body)) + body


def seq(*parts):
    return tlv(0x30, b"".join(parts))


def oid(dotted):
    p = [int(x) for x in dotted.split(".")]
    out = bytes([p[0] * 40 + p[1]])
    for v in p[2:]:
        chunk = [v & 0x7F]
        v >>= 7
        while v:
            chunk.append(0x80 | (v & 0x7F))
            v >>= 7
        out += bytes(reversed(chunk))
    return tlv(0x06, out)


def integer(n):
    return tlv(0x02, n.to_bytes(n.bit_length() // 8 + 1, "big"))


def utctime(dt):
    return tlv(0x17, dt.strftime("%y%m%d%H%M%SZ").encode())


def rdn(o, tag, value):
    return tlv(0x31, seq(oid(o), tlv(tag, value.encode())))


def ca_name(cn):
    return seq(rdn("2.5.4.6", 0x13, "US"), rdn("2.5.4.10", 0x0C, ORG), rdn("2.5.4.3", 0x0C, cn))


def leaf_name(cn):
    return seq(rdn("2.5.4.3", 0x0C, cn))


def ext(o, critical, value):
    return seq(oid(o), tlv(0x01, b"\xff") if critical else b"", tlv(0x04, value))


def pem(der):
    b = base64.b64encode(der).decode()
    lines = [b[i:i + 64] for i in range(0, len(b), 64)]
    return "-----BEGIN CERTIFICATE-----\n" + "\n".join(lines) + "\n-----END CERTIFICATE-----\n"


def unpem(text):
    body = "".join(l for l in text.strip().splitlines() if not l.startswith("-----"))
    return base64.b64decode(body)


# ---- DER reading (strict, definite lengths only) -------------------------

def read_tlv(data, pos):
    """Returns (tag, content, raw, next position)."""
    if pos + 2 > len(data):
        raise RequestError("truncated encoding")
    start = pos
    tag = data[pos]
    first = data[pos + 1]
    pos += 2
    if first & 0x80:
        n = first & 0x7F
        if n == 0 or n > 3 or pos + n > len(data):
            raise RequestError("bad length")
        size = int.from_bytes(data[pos:pos + n], "big")
        pos += n
    else:
        size = first
    if pos + size > len(data):
        raise RequestError("truncated encoding")
    return tag, data[pos:pos + size], data[start:pos + size], pos + size


def children(body):
    out, pos = [], 0
    while pos < len(body):
        tag, content, raw, pos = read_tlv(body, pos)
        out.append((tag, content, raw))
    return out


def whole(data, tag=0x30):
    t, content, raw, end = read_tlv(data, 0)
    if t != tag or end != len(data):
        raise RequestError("unexpected encoding")
    return content


def key_id(spki):
    """Checks that a SubjectPublicKeyInfo is ML-DSA-87 and returns its key identifier
    (RFC 7093 method 2: leftmost 160 bits of SHA-384 over the key bits)."""
    parts = children(whole(spki))
    if len(parts) != 2 or parts[0][2] != seq(oid(ML_DSA_87)):
        raise RequestError("key is not ML-DSA-87")
    tag, bits, _ = parts[1]
    if tag != 0x03 or len(bits) != 2593 or bits[0] != 0:
        raise RequestError("key is not a well-formed ML-DSA-87 key")
    return hashlib.sha384(bits[1:]).digest()[:20]


def request_public_key(request_der):
    """Returns the SubjectPublicKeyInfo of a PKCS#10 request. Does not check the signature."""
    if len(request_der) > 12000:
        raise RequestError("request too large")
    outer = children(whole(request_der))
    if len(outer) != 3:
        raise RequestError("not a certificate request")
    info = children(outer[0][1])
    if len(info) < 3 or info[0][2] != integer(0) or info[2][0] != 0x30:
        raise RequestError("not a certificate request")
    spki = info[2][2]
    key_id(spki)
    return spki


def check_request_signature(request_der):
    """Proof of possession: the request must be signed by the key it carries."""
    with tempfile.NamedTemporaryFile(suffix=".der") as f:
        f.write(request_der)
        f.flush()
        r = subprocess.run([OPENSSL, "req", "-inform", "DER", "-in", f.name, "-verify", "-noout"],
                           capture_output=True, text=True)
    if r.returncode != 0 or "verify OK" not in (r.stdout + r.stderr):
        raise RequestError("request signature does not verify")


def certificate_fields(cert_der):
    """Returns (subject name, SubjectPublicKeyInfo, notAfter) of a certificate, as raw DER / datetime."""
    tbs = children(children(whole(cert_der))[0][1])
    if tbs[0][0] == 0xA0:
        tbs = tbs[1:]
    validity = children(tbs[3][1])
    t = validity[1][1].decode()
    fmt = "%y%m%d%H%M%SZ" if validity[1][0] == 0x17 else "%Y%m%d%H%M%SZ"
    not_after = datetime.datetime.strptime(t, fmt).replace(tzinfo=datetime.timezone.utc)
    return tbs[4][2], tbs[5][2], not_after


# ---- signing --------------------------------------------------------------

_kms_client = None


def _kms():
    """boto3 client, used when LATTICE_KMS=boto3 (the signing server). Credentials come
    from the machine's own role, so nothing is stored on disk."""
    global _kms_client
    if _kms_client is None:
        import boto3
        _kms_client = boto3.client("kms", region_name=REGION)
    return _kms_client


def kms_public_key(key):
    if USE_BOTO3:
        spki = _kms().get_public_key(KeyId=key)["PublicKey"]
    else:
        out = subprocess.run(
            [AWS, "kms", "get-public-key", "--region", REGION, "--key-id", key,
             "--query", "PublicKey", "--output", "text"],
            check=True, capture_output=True, text=True).stdout
        spki = base64.b64decode(out)
    key_id(spki)
    return spki


def kms_signer(key):
    """Returns a function that has AWS KMS sign a message with the given key."""
    def sign(message):
        if len(message) > 4096:
            raise ValueError("certificate body too large for RAW signing")
        if USE_BOTO3:
            return _kms().sign(KeyId=key, Message=message, MessageType="RAW",
                               SigningAlgorithm="ML_DSA_SHAKE_256")["Signature"]
        with tempfile.NamedTemporaryFile(suffix=".der") as f:
            f.write(message)
            f.flush()
            out = subprocess.run(
                [AWS, "kms", "sign", "--region", REGION, "--key-id", key,
                 "--message", "fileb://" + f.name, "--message-type", "RAW",
                 "--signing-algorithm", "ML_DSA_SHAKE_256",
                 "--query", "Signature", "--output", "text"],
                check=True, capture_output=True, text=True).stdout
        return base64.b64decode(out)
    return sign


def new_serial():
    return int.from_bytes(os.urandom(16), "big") | (1 << 126)


def assemble(serial, issuer_name, not_before, not_after, subject_name, subject_spki, extensions, sign):
    alg = seq(oid(ML_DSA_87))
    tbs = seq(
        tlv(0xA0, integer(2)),
        integer(serial),
        alg,
        issuer_name,
        seq(utctime(not_before), utctime(not_after)),
        subject_name,
        subject_spki,
        tlv(0xA3, seq(*extensions)),
    )
    return seq(tbs, alg, tlv(0x03, b"\x00" + sign(tbs)))


def ca_certificate(subject_cn, subject_spki, issuer_cn, issuer_kid, not_before, not_after, path_len, sign):
    serial = new_serial()
    extensions = [
        ext("2.5.29.19", True, seq(tlv(0x01, b"\xff"), integer(path_len))),
        ext("2.5.29.15", True, tlv(0x03, b"\x01\x06")),  # keyCertSign, cRLSign
        ext("2.5.29.14", False, tlv(0x04, key_id(subject_spki))),
        ext("2.5.29.35", False, seq(tlv(0x80, issuer_kid))),
    ]
    der = assemble(serial, ca_name(issuer_cn), not_before, not_after, ca_name(subject_cn),
                   subject_spki, extensions, sign)
    return der, serial


def check_name(kind, name):
    if kind not in ("device", "gateway"):
        raise RequestError("unknown certificate kind")
    if not isinstance(name, str) or len(name) > 64 or not NAME_RE.match(name):
        raise RequestError("name is not acceptable")


def issue_leaf(kind, name, subject_spki, issuing_cert_der, sign, now=None):
    """Issues a device or gateway certificate under the issuing CA.

    Only the public key comes from the requester. Returns (certificate DER, serial, notAfter).
    """
    check_name(kind, name)
    issuer_name, issuer_spki, issuer_end = certificate_fields(issuing_cert_der)
    issuer_kid = key_id(issuer_spki)
    subject_kid = key_id(subject_spki)
    if subject_kid == issuer_kid:
        raise RequestError("key is not acceptable")
    now = now or datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
    not_before = now - datetime.timedelta(minutes=5)
    not_after = now + datetime.timedelta(days=DEVICE_DAYS if kind == "device" else GATEWAY_DAYS)
    if not_after > issuer_end:
        not_after = issuer_end
    if not_after <= now:
        raise ValueError("issuing certificate has expired")
    usage = "1.3.6.1.5.5.7.3.2" if kind == "device" else "1.3.6.1.5.5.7.3.1"
    extensions = [
        ext("2.5.29.19", True, seq()),                       # not a CA
        ext("2.5.29.15", True, tlv(0x03, b"\x07\x80")),      # digitalSignature
        ext("2.5.29.37", False, seq(oid(usage))),
        ext("2.5.29.14", False, tlv(0x04, subject_kid)),
        ext("2.5.29.35", False, seq(tlv(0x80, issuer_kid))),
        ext("2.5.29.17", False, seq(tlv(0x82, name.encode()))),
    ]
    serial = new_serial()
    der = assemble(serial, issuer_name, not_before, not_after, leaf_name(name), subject_spki,
                   extensions, sign)
    return der, serial, not_after
