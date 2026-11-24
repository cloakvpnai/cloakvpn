#!/usr/bin/env python3
"""Lattice VPN CNSA 2.0 signing service.

Takes a certificate request from the account API and returns a device or
gateway certificate signed by the issuing key in AWS KMS. Holds no private key.

  POST /v1/issue   Authorization: Bearer <token>
       {"kind": "device" | "gateway", "name": "<name>", "request": "<base64 PKCS#10>"}
  ->   {"certificate", "issuing", "root" (base64 DER), "serial", "notAfter"}

Only the public key is taken from the request, after its self-signature is
checked. The caller (the account API) decides who may enroll; this service
decides what a certificate may say.

  signing_service.py --certs <dir with root-ca.pem, issuing-ca.pem> --log <issuance log>
                     [--listen 127.0.0.1] [--port 8087] [--per-minute 60]
The token comes from the environment variable LATTICE_CA_TOKEN.
"""
import argparse
import base64
import collections
import hashlib
import hmac
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import latticeca as ca


class Service:
    def __init__(self, certs, log_path, per_minute, sign):
        self.root = ca.unpem(open(os.path.join(certs, "root-ca.pem")).read())
        self.issuing = ca.unpem(open(os.path.join(certs, "issuing-ca.pem")).read())
        self.log_path = log_path
        self.per_minute = per_minute
        self.sign = sign
        self.lock = threading.Lock()
        self.recent = collections.deque()

    def issue(self, body):
        kind, name, request = body.get("kind"), body.get("name"), body.get("request")
        if not isinstance(request, str):
            raise ca.RequestError("request is missing")
        try:
            request_der = base64.b64decode(request, validate=True)
        except Exception:
            raise ca.RequestError("request is not base64")
        ca.check_name(kind, name)
        spki = ca.request_public_key(request_der)
        ca.check_request_signature(request_der)
        with self.lock:
            now = time.time()
            while self.recent and self.recent[0] < now - 60:
                self.recent.popleft()
            if len(self.recent) >= self.per_minute:
                raise OverflowError("rate limit")
            self.recent.append(now)
            der, serial, not_after = ca.issue_leaf(kind, name, spki, self.issuing, self.sign)
            entry = {"time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "kind": kind, "name": name,
                     "serial": "%x" % serial, "notAfter": not_after.strftime("%Y-%m-%dT%H:%M:%SZ"),
                     "sha256": hashlib.sha256(der).hexdigest(),
                     "keyId": ca.key_id(spki).hex()}
            with open(self.log_path, "a") as f:
                f.write(json.dumps(entry, sort_keys=True) + "\n")
                f.flush()
                os.fsync(f.fileno())
        b64 = lambda b: base64.b64encode(b).decode()
        return {"certificate": b64(der), "issuing": b64(self.issuing), "root": b64(self.root),
                "serial": entry["serial"], "notAfter": entry["notAfter"]}


def handler(service, token):
    class Handler(BaseHTTPRequestHandler):
        server_version = "lattice-ca"
        sys_version = ""

        def reply(self, status, obj):
            data = json.dumps(obj).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_POST(self):
            if self.path != "/v1/issue":
                return self.reply(404, {"error": "not found"})
            given = self.headers.get("Authorization", "")
            if not hmac.compare_digest(given.encode(), ("Bearer " + token).encode()):
                return self.reply(401, {"error": "not authorized"})
            try:
                size = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                size = -1
            if size <= 0 or size > 20000:
                return self.reply(413, {"error": "bad request size"})
            try:
                body = json.loads(self.rfile.read(size))
                if not isinstance(body, dict):
                    raise ValueError
            except ValueError:
                return self.reply(400, {"error": "not JSON"})
            try:
                return self.reply(200, service.issue(body))
            except ca.RequestError as e:
                return self.reply(400, {"error": str(e)})
            except OverflowError:
                return self.reply(429, {"error": "too many requests"})
            except Exception as e:  # signing or storage failure: say nothing specific to the caller
                sys.stderr.write("issue failed: %r\n" % (e,))
                return self.reply(503, {"error": "signing unavailable"})

        def log_message(self, fmt, *args):
            sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    return Handler


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--certs", required=True)
    p.add_argument("--log", required=True)
    p.add_argument("--listen", default="127.0.0.1")
    p.add_argument("--port", type=int, default=8087)
    p.add_argument("--per-minute", type=int, default=60)
    a = p.parse_args()
    token = os.environ.get("LATTICE_CA_TOKEN", "")
    if len(token) < 32:
        sys.exit("LATTICE_CA_TOKEN must be set to at least 32 characters")
    service = Service(a.certs, a.log, a.per_minute, ca.kms_signer(ca.ISSUING_KEY))
    # The issuing certificate on disk must match the key KMS will sign with.
    _, issuing_spki, _ = ca.certificate_fields(service.issuing)
    if ca.kms_public_key(ca.ISSUING_KEY) != issuing_spki:
        sys.exit("issuing-ca.pem does not match the KMS issuing key")
    ThreadingHTTPServer((a.listen, a.port), handler(service, token)).serve_forever()


if __name__ == "__main__":
    main()
