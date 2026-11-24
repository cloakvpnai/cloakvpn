#!/usr/bin/env python3
"""Lattice VPN CNSA 2.0 certificate authority: first signing ceremony.

Builds the root and issuing CA certificates (ML-DSA-87, RFC 9881 encoding)
and has AWS KMS sign them. The private keys never leave KMS; this script only
assembles the certificate bodies and attaches the signatures KMS returns.

Usage: ceremony.py <output dir>
Refuses to run if the output files already exist, so a root is never
re-issued by accident.
"""
import base64
import datetime
import hashlib
import os
import subprocess
import sys

AWS = os.environ.get("AWS_CLI", "/opt/homebrew/bin/aws")
REGION = "us-west-2"
ROOT_KEY = "alias/lattice-ca-root"
ISSUING_KEY = "alias/lattice-ca-issuing"
ML_DSA_87 = "2.16.840.1.101.3.4.3.19"
ORG = "Lattice VPN"
ROOT_CN = "Lattice VPN CNSA2 Root CA G1"
ISSUING_CN = "Lattice VPN CNSA2 Issuing CA G1"
ROOT_YEARS = 10
ISSUING_DAYS = 365


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
    b = n.to_bytes(n.bit_length() // 8 + 1, "big")
    return tlv(0x02, b)


def utctime(dt):
    return tlv(0x17, dt.strftime("%y%m%d%H%M%SZ").encode())


def name(cn):
    def rdn(o, tag, value):
        return tlv(0x31, seq(oid(o), tlv(tag, value.encode())))
    return seq(rdn("2.5.4.6", 0x13, "US"), rdn("2.5.4.10", 0x0C, ORG), rdn("2.5.4.3", 0x0C, cn))


def ext(o, critical, value):
    return seq(oid(o), tlv(0x01, b"\xff") if critical else b"", tlv(0x04, value))


def read_tlv(data, pos):
    tag = data[pos]
    first = data[pos + 1]
    pos += 2
    if first & 0x80:
        n = first & 0x7F
        size = int.from_bytes(data[pos:pos + n], "big")
        pos += n
    else:
        size = first
    return tag, data[pos:pos + size], pos + size


def public_key(key):
    out = subprocess.run(
        [AWS, "kms", "get-public-key", "--region", REGION, "--key-id", key,
         "--query", "PublicKey", "--output", "text"],
        check=True, capture_output=True, text=True).stdout
    spki = base64.b64decode(out)
    tag, body, end = read_tlv(spki, 0)
    assert tag == 0x30 and end == len(spki), "unexpected public key encoding"
    tag, alg, pos = read_tlv(body, 0)
    assert seq(oid(ML_DSA_87)) == tlv(0x30, alg), "key is not ML-DSA-87"
    tag, bits, pos = read_tlv(body, pos)
    assert tag == 0x03 and bits[0] == 0 and len(bits) == 2593, "unexpected key length"
    # RFC 7093 method 2: leftmost 160 bits of SHA-384 over the key bits.
    key_id = hashlib.sha384(bits[1:]).digest()[:20]
    return spki, key_id


def kms_sign(key, message, workdir):
    assert len(message) <= 4096, "certificate body too large for RAW signing"
    path = os.path.join(workdir, ".tbs.der")
    with open(path, "wb") as f:
        f.write(message)
    try:
        out = subprocess.run(
            [AWS, "kms", "sign", "--region", REGION, "--key-id", key,
             "--message", "fileb://" + path, "--message-type", "RAW",
             "--signing-algorithm", "ML_DSA_SHAKE_256",
             "--query", "Signature", "--output", "text"],
            check=True, capture_output=True, text=True).stdout
    finally:
        os.remove(path)
    return base64.b64decode(out)


def certificate(subject_cn, subject_spki, subject_kid, issuer_cn, issuer_kid,
                signing_key, not_before, not_after, path_len, workdir):
    serial = int.from_bytes(os.urandom(16), "big") | (1 << 126)
    alg = seq(oid(ML_DSA_87))
    extensions = seq(
        ext("2.5.29.19", True, seq(tlv(0x01, b"\xff"), integer(path_len))),
        ext("2.5.29.15", True, tlv(0x03, b"\x01\x06")),  # keyCertSign, cRLSign
        ext("2.5.29.14", False, tlv(0x04, subject_kid)),
        ext("2.5.29.35", False, seq(tlv(0x80, issuer_kid))),
    )
    tbs = seq(
        tlv(0xA0, integer(2)),
        integer(serial),
        alg,
        name(issuer_cn),
        seq(utctime(not_before), utctime(not_after)),
        name(subject_cn),
        subject_spki,
        tlv(0xA3, extensions),
    )
    signature = kms_sign(signing_key, tbs, workdir)
    return seq(tbs, alg, tlv(0x03, b"\x00" + signature)), serial


def pem(der):
    b = base64.b64encode(der).decode()
    lines = [b[i:i + 64] for i in range(0, len(b), 64)]
    return "-----BEGIN CERTIFICATE-----\n" + "\n".join(lines) + "\n-----END CERTIFICATE-----\n"


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    targets = [os.path.join(out, n) for n in ("root-ca.pem", "issuing-ca.pem")]
    if any(os.path.exists(t) for t in targets):
        sys.exit("certificates already exist in %s; refusing to re-issue" % out)

    root_spki, root_kid = public_key(ROOT_KEY)
    issuing_spki, issuing_kid = public_key(ISSUING_KEY)
    now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
    start = now - datetime.timedelta(minutes=5)

    root, root_serial = certificate(
        ROOT_CN, root_spki, root_kid, ROOT_CN, root_kid, ROOT_KEY,
        start, start.replace(year=start.year + ROOT_YEARS), 1, out)
    issuing, issuing_serial = certificate(
        ISSUING_CN, issuing_spki, issuing_kid, ROOT_CN, root_kid, ROOT_KEY,
        start, start + datetime.timedelta(days=ISSUING_DAYS), 0, out)

    for path, der in zip(targets, (root, issuing)):
        with open(path, "w") as f:
            f.write(pem(der))
    for label, der, serial in (("root", root, root_serial), ("issuing", issuing, issuing_serial)):
        print("%s: %d bytes, serial %x" % (label, len(der), serial))
        print("  sha256 %s" % hashlib.sha256(der).hexdigest())
        print("  sha384 %s" % hashlib.sha384(der).hexdigest())
    print("signed at %s" % now.isoformat())


if __name__ == "__main__":
    main()
