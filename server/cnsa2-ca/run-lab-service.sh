#!/bin/sh
# Lab only: runs the signing service on this Mac, bound to 127.0.0.1, signing with
# the issuing key in AWS KMS through whatever identity the AWS command line tool
# is signed in as. The shared token and the issuance log live outside the repo.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
STATE="${LATTICE_CA_STATE:-$HOME/src/lattice-ca}"; mkdir -p "$STATE"
TOKEN_FILE="${LATTICE_CA_TOKEN_FILE:-$HOME/.lattice-ca-lab-token}"
[ -s "$TOKEN_FILE" ] || (umask 077; python3 -c 'import secrets; print(secrets.token_urlsafe(48))' > "$TOKEN_FILE")
pkill -f "signing_service.py --certs" 2>/dev/null || true
LATTICE_CA_TOKEN="$(cat "$TOKEN_FILE")" nohup python3 "$HERE/signing_service.py" --certs "$HERE/certs" \
  --log "$STATE/issued.log" --port "${LATTICE_CA_PORT:-8087}" >> "$STATE/service.log" 2>&1 &
sleep 4
if pgrep -f "signing_service.py --certs" >/dev/null; then echo "signing service running on 127.0.0.1:${LATTICE_CA_PORT:-8087}"; else tail -3 "$STATE/service.log"; exit 1; fi
