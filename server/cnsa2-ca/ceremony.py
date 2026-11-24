#!/usr/bin/env python3
"""Lattice VPN CNSA 2.0 certificate authority: root and issuing certificate ceremony.

Builds the root and issuing CA certificates (ML-DSA-87) and has the root key in
AWS KMS sign them. The private keys never leave KMS. First run: Nov 23, 2026.

Usage: ceremony.py <output dir>
Refuses to run if the output files already exist, so a root is never
re-issued by accident. The root key is kept disabled between uses and must be
enabled for this to work.
"""
import datetime
import hashlib
import os
import sys

import latticeca as ca

ROOT_CN = "Lattice VPN CNSA2 Root CA G1"
ISSUING_CN = "Lattice VPN CNSA2 Issuing CA G1"
ROOT_YEARS = 10
ISSUING_DAYS = 365


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    targets = [os.path.join(out, n) for n in ("root-ca.pem", "issuing-ca.pem")]
    if any(os.path.exists(t) for t in targets):
        sys.exit("certificates already exist in %s; refusing to re-issue" % out)

    root_spki = ca.kms_public_key(ca.ROOT_KEY)
    issuing_spki = ca.kms_public_key(ca.ISSUING_KEY)
    root_kid = ca.key_id(root_spki)
    sign = ca.kms_signer(ca.ROOT_KEY)
    now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
    start = now - datetime.timedelta(minutes=5)

    root, root_serial = ca.ca_certificate(
        ROOT_CN, root_spki, ROOT_CN, root_kid,
        start, start.replace(year=start.year + ROOT_YEARS), 1, sign)
    issuing, issuing_serial = ca.ca_certificate(
        ISSUING_CN, issuing_spki, ROOT_CN, root_kid,
        start, start + datetime.timedelta(days=ISSUING_DAYS), 0, sign)

    for path, der in zip(targets, (root, issuing)):
        with open(path, "w") as f:
            f.write(ca.pem(der))
    for label, der, serial in (("root", root, root_serial), ("issuing", issuing, issuing_serial)):
        print("%s: %d bytes, serial %x" % (label, len(der), serial))
        print("  sha256 %s" % hashlib.sha256(der).hexdigest())
        print("  sha384 %s" % hashlib.sha384(der).hexdigest())
    print("signed at %s" % now.isoformat())


if __name__ == "__main__":
    main()
