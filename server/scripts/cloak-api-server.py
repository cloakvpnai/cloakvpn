#!/usr/bin/env python3
"""
Cloak VPN — Provisioning API server.

Replaces the manual AirDrop+scp+base64 dance for adding a new peer to a
region. The iOS app POSTs its locally-generated WG + rosenpass public
keys; this service writes them to the right places under
/etc/wireguard and /etc/rosenpass via add-peer.sh, hot-reloads the
running daemons, and returns a complete client config block that the
app can import directly.

Privacy property: this service never sees, generates, or persists ANY
private keys. Both the iPhone's WG private key and its rosenpass
private key live exclusively on the device. Server compromise here does
not retroactively decrypt any session.

Endpoints:
    POST  /api/v1/auth/exchange  — exchange a device-installation
                                   token (or, in future, a StoreKit
                                   transaction JWS) for a short-lived
                                   JWT used to authorize provisioning
                                   calls. Returns {"jwt": "...",
                                                  "exp": <unix-ts>}.
                                   Auth: X-Cloak-Bootstrap-Key header
                                   matches the per-install bootstrap
                                   secret in /etc/cloak/bootstrap-key.
    POST  /api/v1/peers   — register a new peer.
                                   Auth: Authorization: Bearer <jwt>
    GET   /api/v1/health  — liveness probe (no auth required).

Auth model:
    Phase 1 (current — pre-IAP):
        iOS app has a hardcoded bootstrap key (per-install will
        replace this when StoreKit is wired). It POSTs that key
        to /api/v1/auth/exchange with an installation UUID and
        gets back a JWT signed with HS256 against
        /etc/cloak/jwt-secret. JWT lifetime = 24 hours.

    Phase 2 (when IAP ships):
        iOS app drops bootstrap key path. Instead grabs the
        StoreKit 2 transaction JWS from
        Transaction.currentEntitlements, sends it to
        /api/v1/auth/exchange, server verifies the JWS signature
        against Apple's published public key, then issues a JWT
        bound to the originalTransactionID.

    Either way, downstream provisioning uses Authorization: Bearer
    <jwt> — there's only one validation path for /api/v1/peers
    regardless of how the JWT was obtained.

    LEGACY: X-Cloak-API-Key header still accepted on /api/v1/peers
    for one transition window. Will be removed in a follow-up
    commit once iOS app is fully on JWT auth.

Request body (POST /api/v1/peers):
    {
      "peer_name":            "<[A-Za-z0-9._-]+>",   optional; auto-generated from rp pubkey hash if absent
      "wg_pubkey_b64":        "<44 char base64>",
      "rosenpass_pubkey_b64": "<~700 KB base64>"
    }

Response (200 OK, body = config block as INI text):
    [wireguard]
    address_v4  = 10.99.0.X/32
    address_v6  = fd42:99::X/128
    dns         = 9.9.9.9, 2620:fe::fe

    [wireguard.peer]
    public_key = <server-wg-pub>
    endpoint   = <region-ip>:51820
    allowed_ips = 0.0.0.0/0, ::/0
    persistent_keepalive = 25

    [rosenpass]
    server_public_key_b64 = ...
    server_endpoint       = <region-ip>:9999
    psk_rotation_seconds  = 120
    ### END_CLIENT_CONFIG ###

Error responses are application/json with {"error": "..."}.

Production deployment: bind to localhost and expose via nginx + Let's
Encrypt for TLS termination. For initial testing this binds 0.0.0.0:8443
plain HTTP. The wire payload only contains public keys (no private
material), so plain-HTTP for testing doesn't leak crypto material — but
the API key in the header IS sent in the clear, so use TLS in production.
"""

import base64
import hashlib
import hmac
import http.server
import json
import os
import re
import socket
import socketserver
import subprocess
import sys
import threading
import time
import traceback
from typing import Optional

# ---------- Configuration -----------------------------------------------------

API_TOKEN_FILE = os.environ.get("CLOAK_API_TOKEN_FILE", "/etc/cloak/api-token")
LISTEN_HOST = os.environ.get("CLOAK_API_HOST", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("CLOAK_API_PORT", "8443"))
ADD_PEER_SCRIPT = os.environ.get("CLOAK_API_ADD_PEER", "/usr/local/bin/add-peer.sh")

# JWT signing secret — used to mint and verify JWTs for the auth path.
# Generated once per region by setup_https.sh (or by hand:
#   openssl rand -base64 64 > /etc/cloak/jwt-secret
#   chmod 600 /etc/cloak/jwt-secret
# ) and READ at startup. Must be IDENTICAL across all regions if you
# want a JWT issued by region A to be valid for region B (so the iOS
# app doesn't have to re-bootstrap when switching regions). Generate
# once on us-west-1 and rsync to the other 3.
JWT_SECRET_FILE = os.environ.get("CLOAK_JWT_SECRET_FILE", "/etc/cloak/jwt-secret")
JWT_LIFETIME_SECONDS = int(os.environ.get("CLOAK_JWT_LIFETIME_SECONDS", str(24 * 3600)))
JWT_ISSUER = "cloak-auth"

# Bootstrap key — the per-install secret iOS uses to authenticate the
# /api/v1/auth/exchange call BEFORE it has a JWT. This is a transition
# mechanism until StoreKit IAP is wired (at which point the iOS app
# will send a real Apple-signed transaction JWS instead). Same secret
# across all installs in this phase; a leak gives an attacker the
# ability to mint JWTs (which are still rate-limit-able later) but
# can't bypass per-customer revocation once IAP is live.
BOOTSTRAP_KEY_FILE = os.environ.get("CLOAK_BOOTSTRAP_KEY_FILE", "/etc/cloak/bootstrap-key")

# Format constraints — keep loose enough that we don't need to crack
# open base64 ourselves but tight enough that obvious bad input gets a
# 400 instead of crashing add-peer.sh.
RE_PEER_NAME = re.compile(r"^[a-zA-Z0-9._-]{1,64}$")
RE_WG_PUBKEY_B64 = re.compile(r"^[A-Za-z0-9+/]{43}=$")            # exactly 44 chars
# Rosenpass McEliece-460896 public key = 524160 bytes → ~700 KB base64.
# We don't insist on exact length here because base64 padding may vary
# with whitespace; we validate the decoded bytes downstream in
# add-peer.sh (which checks decoded size == 524160).
RE_RP_PUBKEY_B64 = re.compile(r"^[A-Za-z0-9+/=\s]{500000,1000000}$")


# ---------- Helpers -----------------------------------------------------------

def load_api_token() -> str:
    try:
        with open(API_TOKEN_FILE, "r") as f:
            t = f.read().strip()
        if not t:
            print(f"ERROR: {API_TOKEN_FILE} is empty", file=sys.stderr)
            sys.exit(2)
        return t
    except FileNotFoundError:
        print(f"ERROR: API token file {API_TOKEN_FILE} not found.", file=sys.stderr)
        print(f"Generate one with: openssl rand -base64 32 > {API_TOKEN_FILE}",
              file=sys.stderr)
        sys.exit(2)


def constant_time_eq(a: str, b: str) -> bool:
    """Avoid timing oracle on the API token."""
    if len(a) != len(b):
        return False
    diff = 0
    for x, y in zip(a, b):
        diff |= ord(x) ^ ord(y)
    return diff == 0


def auto_peer_name(rp_pubkey_b64: str) -> str:
    """Derive a stable peer name from the rosenpass pubkey hash. The
    same iPhone re-registering will get the same name — useful for
    overwriting on reinstall without polluting the [Peer] table.
    Format: 'cloak-<8 hex chars>'."""
    h = hashlib.sha256(rp_pubkey_b64.encode("utf-8")).hexdigest()
    return f"cloak-{h[:8]}"


def load_secret_file(path: str, label: str, generate_hint: str) -> bytes:
    """Generic secret-file loader. Returns the bytes; exits if missing
    or empty. The label/hint go into the error message."""
    try:
        with open(path, "rb") as f:
            data = f.read().strip()
        if not data:
            print(f"ERROR: {path} is empty (need {label})", file=sys.stderr)
            sys.exit(2)
        return data
    except FileNotFoundError:
        print(f"ERROR: {label} file {path} not found.", file=sys.stderr)
        print(f"Generate with: {generate_hint}", file=sys.stderr)
        sys.exit(2)


# ---------- JWT (HS256, pure stdlib) -----------------------------------------
#
# Implements just enough of RFC 7519 + RFC 7515 (JWS HS256) to mint and
# verify our own tokens. We deliberately don't depend on PyJWT to keep
# this server stdlib-only (matches cloak-api-server's existing posture
# and avoids `pip install` surprises during region rebuilds).
#
# Token shape:
#   header  = {"alg":"HS256","typ":"JWT"}
#   payload = {
#       "sub": "<install-uuid OR originalTransactionID>",
#       "iat": <unix-ts>,
#       "exp": <unix-ts>,
#       "iss": "cloak-auth",
#       "tier": "basic" | "pro" | "dev",
#       "aud": "cloak-api"
#   }
#   signature = HMAC-SHA256(secret, base64url(header) + "." + base64url(payload))
#
# Cross-region note: as long as JWT_SECRET_FILE is identical on every
# region, a JWT issued by region A authorizes calls to region B.

def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _b64url_decode(s: str) -> bytes:
    pad = -len(s) % 4
    return base64.urlsafe_b64decode(s + ("=" * pad))


def jwt_sign(payload: dict, secret: bytes) -> str:
    header = {"alg": "HS256", "typ": "JWT"}
    h = _b64url(json.dumps(header, separators=(",", ":")).encode())
    p = _b64url(json.dumps(payload, separators=(",", ":"), sort_keys=True).encode())
    msg = f"{h}.{p}".encode()
    sig = hmac.new(secret, msg, hashlib.sha256).digest()
    return f"{h}.{p}.{_b64url(sig)}"


def jwt_verify(token: str, secret: bytes) -> dict:
    """Returns the decoded payload if the token is valid + unexpired.
    Raises ValueError otherwise."""
    parts = token.split(".")
    if len(parts) != 3:
        raise ValueError("malformed JWT (need 3 parts)")
    h_b64, p_b64, sig_b64 = parts
    expected = hmac.new(secret, f"{h_b64}.{p_b64}".encode(), hashlib.sha256).digest()
    try:
        actual = _b64url_decode(sig_b64)
    except Exception:
        raise ValueError("malformed JWT signature")
    if not hmac.compare_digest(expected, actual):
        raise ValueError("invalid JWT signature")
    try:
        payload = json.loads(_b64url_decode(p_b64))
    except Exception:
        raise ValueError("malformed JWT payload")
    now = int(time.time())
    if int(payload.get("exp", 0)) < now:
        raise ValueError("JWT expired")
    if payload.get("iss") != JWT_ISSUER:
        raise ValueError(f"unexpected iss: {payload.get('iss')}")
    return payload


def mint_jwt_for(subject: str, tier: str = "dev") -> tuple[str, int]:
    """Issue a fresh JWT for the given subject (install UUID or Apple
    originalTransactionID). Returns (token, exp_unix_ts)."""
    iat = int(time.time())
    exp = iat + JWT_LIFETIME_SECONDS
    payload = {
        "sub": subject,
        "iat": iat,
        "exp": exp,
        "iss": JWT_ISSUER,
        "aud": "cloak-api",
        "tier": tier,
    }
    return jwt_sign(payload, JWT_SECRET), exp


# ---------- HTTP handler ------------------------------------------------------

class CloakHandler(http.server.BaseHTTPRequestHandler):
    server_version = "cloak-api/0.1"

    def _json_error(self, status: int, message: str):
        body = json.dumps({"error": message}).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        # Route HTTPServer's stderr logs through systemd-journal-friendly
        # stdout instead.
        sys.stdout.write(
            f"[cloak-api] {self.address_string()} - {format % args}\n"
        )
        sys.stdout.flush()

    # ---- GET /api/v1/health ----------------------------------------------

    def do_GET(self):
        if self.path == "/api/v1/health":
            body = b'{"status":"ok"}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self._json_error(404, "not found")

    # ---- POST /api/v1/auth/exchange -------------------------------------

    def _handle_auth_exchange(self):
        """Exchange a bootstrap secret + install UUID for a fresh JWT."""
        provided = self.headers.get("X-Cloak-Bootstrap-Key", "")
        if not constant_time_eq(provided, BOOTSTRAP_KEY):
            self._json_error(401, "unauthorized")
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self._json_error(400, "bad Content-Length")
            return
        if length <= 0 or length > 4096:
            self._json_error(400, "bad body length")
            return
        try:
            body = json.loads(self.rfile.read(length))
        except json.JSONDecodeError:
            self._json_error(400, "body is not valid JSON")
            return

        # Phase 1: install_uuid path. Phase 2: storekit_jws path goes here.
        install_uuid = (body.get("install_uuid") or "").strip()
        if install_uuid and re.match(r"^[A-Fa-f0-9-]{8,72}$", install_uuid):
            jwt, exp = mint_jwt_for(f"install:{install_uuid}", tier="dev")
            payload = json.dumps({"jwt": jwt, "exp": exp}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return

        # storekit_jws = body.get("storekit_jws") — TODO Phase 2
        self._json_error(400, "missing or malformed install_uuid (Phase 2 storekit_jws not yet implemented)")

    # ---- POST /api/v1/peers ---------------------------------------------

    def _check_provision_auth(self) -> bool:
        """Authorize a /api/v1/peers call. Accepts either:
           1. NEW: Authorization: Bearer <jwt>  (HS256 against JWT_SECRET)
           2. LEGACY: X-Cloak-API-Key: <token>  (transition path; will
              be removed in a follow-up commit)
        Returns True if authorized."""
        # Path 1: JWT
        bearer = self.headers.get("Authorization", "")
        if bearer.startswith("Bearer "):
            try:
                payload = jwt_verify(bearer[7:].strip(), JWT_SECRET)
                # Stash on the request for logging
                self._jwt_subject = payload.get("sub", "?")
                return True
            except ValueError as e:
                sys.stdout.write(f"[cloak-api] JWT rejected: {e}\n")
                sys.stdout.flush()
                # Fall through to legacy check; if THAT also fails we 401
        # Path 2: legacy API key
        provided_token = self.headers.get("X-Cloak-API-Key", "")
        if provided_token and constant_time_eq(provided_token, API_TOKEN):
            self._jwt_subject = "legacy-api-key"
            return True
        return False

    def do_POST(self):
        if self.path == "/api/v1/auth/exchange":
            self._handle_auth_exchange()
            return
        if self.path != "/api/v1/peers":
            self._json_error(404, "not found")
            return

        # Auth (JWT preferred, legacy API key still accepted)
        if not self._check_provision_auth():
            self._json_error(401, "unauthorized")
            return

        # Body
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self._json_error(400, "bad Content-Length")
            return
        if length <= 0 or length > 2_000_000:  # 2 MB cap (rp pubkey ~700 KB)
            self._json_error(400, "request body too small or too large")
            return
        raw = self.rfile.read(length)
        try:
            body = json.loads(raw)
        except json.JSONDecodeError:
            self._json_error(400, "body is not valid JSON")
            return

        # Validate fields
        wg_b64 = body.get("wg_pubkey_b64", "").strip()
        rp_b64 = body.get("rosenpass_pubkey_b64", "").strip()
        peer_name = body.get("peer_name") or auto_peer_name(rp_b64)

        if not RE_PEER_NAME.match(peer_name):
            self._json_error(400, "peer_name must match [a-zA-Z0-9._-]{1,64}")
            return
        if not RE_WG_PUBKEY_B64.match(wg_b64):
            self._json_error(400, "wg_pubkey_b64 must be 44-char base64")
            return
        if not RE_RP_PUBKEY_B64.match(rp_b64):
            self._json_error(400, "rosenpass_pubkey_b64 must be base64 of ~524160-byte McEliece pubkey")
            return

        # Decode rp pubkey to verify length matches McEliece-460896
        try:
            rp_bytes = base64.b64decode(rp_b64, validate=False)
        except Exception:
            self._json_error(400, "rosenpass_pubkey_b64 not valid base64")
            return
        if len(rp_bytes) != 524160:
            self._json_error(400,
                f"rosenpass_pubkey_b64 decoded to {len(rp_bytes)} bytes; expected 524160 (McEliece-460896)")
            return

        # Write rp pubkey to a tmp file for add-peer.sh to consume
        rp_pubkey_tmp = f"/tmp/cloak-rp-pubkey-{peer_name}.b64"
        try:
            with open(rp_pubkey_tmp, "w") as f:
                f.write(rp_b64)
            os.chmod(rp_pubkey_tmp, 0o600)
        except OSError as e:
            self._json_error(500, f"failed to stage pubkey: {e}")
            return

        # Run add-peer.sh
        try:
            result = subprocess.run(
                [ADD_PEER_SCRIPT, peer_name, rp_pubkey_tmp, wg_b64],
                check=False,
                capture_output=True,
                text=True,
                timeout=30,
            )
        except subprocess.TimeoutExpired:
            self._json_error(500, "add-peer.sh timed out")
            return
        finally:
            try:
                os.remove(rp_pubkey_tmp)
            except OSError:
                pass

        if result.returncode != 0:
            stderr_tail = (result.stderr or "")[-2000:]
            sys.stdout.write(
                f"[cloak-api] add-peer.sh failed (rc={result.returncode}) for {peer_name}\n"
                f"  stderr: {stderr_tail}\n"
            )
            sys.stdout.flush()
            self._json_error(500, "add-peer.sh failed; see server logs")
            return

        # Extract the config block from add-peer.sh stdout. The script
        # prints noise around the config (logs, separators, etc.); we
        # match between the two known sentinels.
        stdout = result.stdout or ""
        config = self._extract_config_block(stdout)
        if config is None:
            sys.stdout.write(
                f"[cloak-api] could not parse add-peer.sh output for {peer_name}\n"
                f"  stdout tail: {stdout[-1500:]}\n"
            )
            sys.stdout.flush()
            self._json_error(500, "add-peer.sh succeeded but config not found in output")
            return

        body_bytes = config.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body_bytes)))
        self.send_header("X-Cloak-Peer-Name", peer_name)
        self.end_headers()
        self.wfile.write(body_bytes)

    @staticmethod
    def _extract_config_block(stdout: str) -> Optional[str]:
        """add-peer.sh prints the config between '----- CLIENT CONFIG'
        and a trailing dashes-only line. Pull just that block out."""
        m_start = re.search(r"^\[wireguard\]\s*$", stdout, re.MULTILINE)
        if not m_start:
            return None
        # End at the line of dashes that follows the config block.
        end_pat = re.compile(r"^-{10,}\s*$", re.MULTILINE)
        m_end = end_pat.search(stdout, m_start.start())
        if not m_end:
            # Fall back to end of stdout
            return stdout[m_start.start():].strip() + "\n### END_CLIENT_CONFIG ###\n"
        block = stdout[m_start.start():m_end.start()].rstrip()
        return block + "\n### END_CLIENT_CONFIG ###\n"


class ThreadedHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    """Threaded so a slow add-peer.sh doesn't block the health probe."""
    allow_reuse_address = True
    daemon_threads = True


# ---------- Entry point -------------------------------------------------------

def main():
    global API_TOKEN, JWT_SECRET, BOOTSTRAP_KEY
    API_TOKEN = load_api_token()
    JWT_SECRET = load_secret_file(
        JWT_SECRET_FILE, "JWT signing secret",
        f"openssl rand -base64 64 > {JWT_SECRET_FILE} && chmod 600 {JWT_SECRET_FILE}"
    )
    BOOTSTRAP_KEY = load_secret_file(
        BOOTSTRAP_KEY_FILE, "iOS bootstrap key",
        f"openssl rand -base64 32 > {BOOTSTRAP_KEY_FILE} && chmod 600 {BOOTSTRAP_KEY_FILE}"
    ).decode("ascii", errors="replace").strip()
    print(f"[cloak-api] loaded API token (len={len(API_TOKEN)}), "
          f"JWT secret (len={len(JWT_SECRET)}), "
          f"bootstrap key (len={len(BOOTSTRAP_KEY)})",
          flush=True)

    # IPv6-and-IPv4 dual stack: bind to AF_INET6 and let the kernel handle
    # mapped IPv4. If LISTEN_HOST is "0.0.0.0" we override to "::" for
    # dual-stack; the operator can pin to a specific v4/v6 by setting
    # CLOAK_API_HOST explicitly.
    listen = LISTEN_HOST if LISTEN_HOST != "0.0.0.0" else "::"
    addr_family = socket.AF_INET6 if ":" in listen else socket.AF_INET

    class _Server(ThreadedHTTPServer):
        address_family = addr_family

    server = _Server((listen, LISTEN_PORT), CloakHandler)
    print(f"[cloak-api] listening on {listen}:{LISTEN_PORT} "
          f"(family={addr_family.name})",
          flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("[cloak-api] shutting down", flush=True)
        server.shutdown()


if __name__ == "__main__":
    try:
        main()
    except Exception:
        traceback.print_exc()
        sys.exit(1)
