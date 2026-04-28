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
    POST  /api/v1/peers   — register a new peer
    GET   /api/v1/health  — liveness probe (no auth required)

Auth:
    X-Cloak-API-Key: <token>   (must match /etc/cloak/api-token)

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
import http.server
import json
import os
import re
import socket
import socketserver
import subprocess
import sys
import threading
import traceback
from typing import Optional

# ---------- Configuration -----------------------------------------------------

API_TOKEN_FILE = os.environ.get("CLOAK_API_TOKEN_FILE", "/etc/cloak/api-token")
LISTEN_HOST = os.environ.get("CLOAK_API_HOST", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("CLOAK_API_PORT", "8443"))
ADD_PEER_SCRIPT = os.environ.get("CLOAK_API_ADD_PEER", "/usr/local/bin/add-peer.sh")

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

    # ---- POST /api/v1/peers ---------------------------------------------

    def do_POST(self):
        if self.path != "/api/v1/peers":
            self._json_error(404, "not found")
            return

        # Auth
        provided_token = self.headers.get("X-Cloak-API-Key", "")
        if not constant_time_eq(provided_token, API_TOKEN):
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
    global API_TOKEN
    API_TOKEN = load_api_token()
    print(f"[cloak-api] loaded API token from {API_TOKEN_FILE} (len={len(API_TOKEN)})",
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
