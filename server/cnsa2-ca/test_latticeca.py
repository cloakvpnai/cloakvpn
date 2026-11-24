"""Tests for the certificate authority code. Uses throwaway local keys, never AWS.

  python3 -m unittest test_latticeca -v      (needs OpenSSL 3.5 or later)
"""
import base64
import datetime
import json
import os
import subprocess
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

import latticeca as ca
import signing_service

SSL = ca.OPENSSL


def run(*args, **kw):
    return subprocess.run([SSL, *args], capture_output=True, text=True, **kw)


class Authority(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        d = cls.d = cls.tmp.name
        for n in ("root", "issuing", "device", "other"):
            assert run("genpkey", "-algorithm", "ML-DSA-87", "-out", f"{d}/{n}.key").returncode == 0
        cls.root_spki = cls.spki("root")
        cls.issuing_spki = cls.spki("issuing")
        now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
        root, _ = ca.ca_certificate("Test Root", cls.root_spki, "Test Root", ca.key_id(cls.root_spki),
                                    now, now + datetime.timedelta(days=30), 1, cls.signer("root"))
        cls.issuing, _ = ca.ca_certificate("Test Issuing", cls.issuing_spki, "Test Root",
                                           ca.key_id(cls.root_spki), now,
                                           now + datetime.timedelta(days=20), 0, cls.signer("root"))
        open(f"{d}/root-ca.pem", "w").write(ca.pem(root))
        open(f"{d}/issuing-ca.pem", "w").write(ca.pem(cls.issuing))
        cls.request = cls.make_request("device")

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    @classmethod
    def spki(cls, name):
        r = subprocess.run([SSL, "pkey", "-in", f"{cls.d}/{name}.key", "-pubout", "-outform", "DER"],
                           capture_output=True, check=True)
        return r.stdout

    @classmethod
    def signer(cls, name):
        def sign(message):
            with tempfile.NamedTemporaryFile() as f:
                f.write(message)
                f.flush()
                r = subprocess.run([SSL, "pkeyutl", "-sign", "-inkey", f"{cls.d}/{name}.key", "-in", f.name],
                                   capture_output=True, check=True)
            return r.stdout
        return sign

    @classmethod
    def make_request(cls, key, subject="/CN=whatever.the.client.says"):
        r = subprocess.run([SSL, "req", "-new", "-key", f"{cls.d}/{key}.key", "-subj", subject, "-outform", "DER"],
                           capture_output=True, check=True)
        return r.stdout

    def verify(self, der, purpose):
        path = f"{self.d}/leaf.pem"
        open(path, "w").write(ca.pem(der))
        return run("verify", "-x509_strict", "-purpose", purpose, "-CAfile", f"{self.d}/root-ca.pem",
                   "-untrusted", f"{self.d}/issuing-ca.pem", path)

    def text(self, der):
        open(f"{self.d}/leaf.pem", "w").write(ca.pem(der))
        return run("x509", "-in", f"{self.d}/leaf.pem", "-noout", "-text").stdout

    def test_chain_verifies(self):
        r = run("verify", "-x509_strict", "-CAfile", f"{self.d}/root-ca.pem", f"{self.d}/issuing-ca.pem")
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_device_certificate(self):
        spki = ca.request_public_key(self.request)
        ca.check_request_signature(self.request)
        der, serial, end = ca.issue_leaf("device", "dev-7f3a.lattice", spki, self.issuing, self.signer("issuing"))
        self.assertEqual(self.verify(der, "sslclient").returncode, 0)
        self.assertNotEqual(self.verify(der, "sslserver").returncode, 0)
        t = self.text(der)
        self.assertIn("CA:FALSE", t)
        self.assertIn("DNS:dev-7f3a.lattice", t)
        self.assertIn("Subject: CN=dev-7f3a.lattice", t)
        self.assertNotIn("whatever.the.client.says", t)
        self.assertIn("TLS Web Client Authentication", t)

    def test_gateway_certificate(self):
        spki = ca.request_public_key(self.request)
        der, _, _ = ca.issue_leaf("gateway", "lab.gw.latticevpn.ai", spki, self.issuing, self.signer("issuing"))
        self.assertEqual(self.verify(der, "sslserver").returncode, 0)
        self.assertNotEqual(self.verify(der, "sslclient").returncode, 0)

    def test_lifetime_never_outlives_issuer(self):
        spki = ca.request_public_key(self.request)
        _, _, issuer_end = ca.certificate_fields(self.issuing)
        _, _, end = ca.issue_leaf("gateway", "a.b", spki, self.issuing, self.signer("issuing"))
        self.assertEqual(end, issuer_end)
        _, _, end = ca.issue_leaf("device", "a.b", spki, self.issuing, self.signer("issuing"))
        self.assertEqual(end, issuer_end)  # issuer here lasts 20 days, device default is 30

    def test_leaf_cannot_sign_certificates(self):
        spki = ca.request_public_key(self.request)
        leaf, _, _ = ca.issue_leaf("device", "a.b", spki, self.issuing, self.signer("issuing"))
        now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
        name, leaf_spki, _ = ca.certificate_fields(leaf)
        other = self.spki("other")
        forged = ca.assemble(ca.new_serial(), name, now, now + datetime.timedelta(days=1),
                             ca.leaf_name("evil"), other,
                             [ca.ext("2.5.29.35", False, ca.seq(ca.tlv(0x80, ca.key_id(leaf_spki))))],
                             self.signer("device"))
        open(f"{self.d}/forged.pem", "w").write(ca.pem(forged))
        open(f"{self.d}/chain.pem", "w").write(ca.pem(self.issuing) + ca.pem(leaf))
        r = run("verify", "-CAfile", f"{self.d}/root-ca.pem", "-untrusted", f"{self.d}/chain.pem", f"{self.d}/forged.pem")
        self.assertNotEqual(r.returncode, 0)

    def test_bad_names(self):
        spki = ca.request_public_key(self.request)
        for name in ("", "UPPER.case", "a b", "*.latticevpn.ai", "a..b", "-a.b", "x" * 65, "a/b", None, 7):
            with self.assertRaises(ca.RequestError, msg=repr(name)):
                ca.issue_leaf("device", name, spki, self.issuing, self.signer("issuing"))
        with self.assertRaises(ca.RequestError):
            ca.issue_leaf("ca", "a.b", spki, self.issuing, self.signer("issuing"))

    def test_issuing_key_cannot_be_enrolled(self):
        with self.assertRaises(ca.RequestError):
            ca.issue_leaf("device", "a.b", self.issuing_spki, self.issuing, self.signer("issuing"))

    def test_tampered_request(self):
        bad = bytearray(self.request)
        bad[-10] ^= 1
        with self.assertRaises(ca.RequestError):
            ca.check_request_signature(bytes(bad))

    def test_request_signed_by_other_key(self):
        # Take the public key from one request and the signature from another.
        a = ca.children(ca.whole(self.request))
        b = ca.children(ca.whole(self.make_request("other")))
        mixed = ca.seq(a[0][2], b[1][2], b[2][2])
        ca.request_public_key(mixed)
        with self.assertRaises(ca.RequestError):
            ca.check_request_signature(mixed)

    def test_wrong_algorithm(self):
        run("genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-384", "-out", f"{self.d}/ec.key")
        with self.assertRaises(ca.RequestError):
            ca.request_public_key(self.make_request("ec"))
        run("genpkey", "-algorithm", "ML-DSA-65", "-out", f"{self.d}/m65.key")
        with self.assertRaises(ca.RequestError):
            ca.request_public_key(self.make_request("m65"))

    def test_garbage(self):
        for blob in (b"", b"\x30", b"\x30\x80\x00\x00", os.urandom(200), b"\x30\x84\xff\xff\xff\xff", self.request[:-1],
                     self.request + b"\x00"):
            with self.assertRaises(ca.RequestError):
                ca.request_public_key(blob)

    def test_service(self):
        log = f"{self.d}/issued.log"
        svc = signing_service.Service(self.d, log, 3, self.signer("issuing"))
        token = "t" * 40
        httpd = ThreadingHTTPServer(("127.0.0.1", 0), signing_service.handler(svc, token))
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        url = "http://127.0.0.1:%d/v1/issue" % httpd.server_address[1]

        def post(body, tok=token, raw=None):
            req = urllib.request.Request(url, data=raw if raw is not None else json.dumps(body).encode(),
                                         headers={"Authorization": "Bearer " + tok})
            try:
                with urllib.request.urlopen(req) as r:
                    return r.status, json.loads(r.read())
            except urllib.error.HTTPError as e:
                return e.code, json.loads(e.read())

        good = {"kind": "device", "name": "phone.test", "request": base64.b64encode(self.request).decode()}
        try:
            self.assertEqual(post(good, tok="wrong" * 8)[0], 401)
            self.assertEqual(post(None, raw=b"not json")[0], 400)
            self.assertEqual(post({**good, "name": "Bad Name"})[0], 400)
            self.assertEqual(post({**good, "kind": "root"})[0], 400)
            self.assertEqual(post({**good, "request": "!!!"})[0], 400)
            self.assertFalse(os.path.exists(log))
            status, out = post(good)
            self.assertEqual(status, 200)
            der = base64.b64decode(out["certificate"])
            self.assertEqual(self.verify(der, "sslclient").returncode, 0)
            _, spki, _ = ca.certificate_fields(der)
            self.assertEqual(spki, ca.request_public_key(self.request))
            entry = json.loads(open(log).read().splitlines()[0])
            self.assertEqual(entry["serial"], out["serial"])
            self.assertEqual(entry["name"], "phone.test")
            self.assertEqual(post(good)[0], 200)
            self.assertEqual(post(good)[0], 200)
            self.assertEqual(post(good)[0], 429)  # limit is 3 a minute in this test
            self.assertEqual(len(open(log).read().splitlines()), 3)
        finally:
            httpd.shutdown()


if __name__ == "__main__":
    unittest.main()
