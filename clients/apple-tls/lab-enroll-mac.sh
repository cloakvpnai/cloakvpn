#!/bin/sh
# Lab only: enrolls this Mac's Lattice app (debug build in /Applications) with the
# TLS lab CA, then starts its CNSA 2.0 tunnel against the lab gateway on this Mac.
# The key is made by the app and stays in the keychain; only the request comes out.
#   lab-enroll-mac.sh <device name, e.g. macmini.tls.lattice.lab> <rekey seconds>
set -eu
NAME="$1"; REKEY="${2:-300}"
HERE="$(cd "$(dirname "$0")" && pwd)"; PKI="$HERE/../../server/cnsa2-tls/lab/pki"
APP=/Applications/LatticeMac.app
W="$HOME/src/cnsa2-enroll-mac.$$"; mkdir -p "$W"; trap 'rm -rf "$W"' EXIT
quit() { osascript -e 'tell application "LatticeMac" to quit' >/dev/null 2>&1 || true; sleep 2; pkill -x LatticeMac 2>/dev/null || true; }
quit
open -a "$APP" --args -LatticeCNSA2Enroll "$NAME"
sleep 8
/usr/bin/log show --last 30s --predicate 'subsystem == "ai.cloakvpn.CloakVPN" AND category == "cnsa2lab"' 2>/dev/null \
  | sed -n 's/.*cnsa2lab: request \([0-9]*\)\/[0-9]* \(.*\)$/\1 \2/p' | sort -n -u -k1,1 | cut -d' ' -f2 | tr -d '\n' | base64 -D > "$W/request.der"
printf 'basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth\nsubjectAltName=DNS:%s\n' "$NAME" > "$W/ext"
docker run --rm -v "$PKI:/pki:ro" -v "$W:/w" lattice-cnsa2-tls-lab sh -euc '
  openssl req -inform DER -in /w/request.der -verify -noout 2>&1 | head -1
  openssl x509 -req -inform DER -in /w/request.der -CA /pki/ca.pem -CAkey /pki/ca.key -CAcreateserial -CAserial /w/serial \
    -days 30 -extfile /w/ext -outform DER -out /w/client.der 2>/dev/null
  openssl x509 -inform DER -in /w/client.der -noout -subject -enddate'
BLOB=$(python3 - "$PKI" "$REKEY" <<'PY'
import sys, json, base64, ssl
ca = base64.b64encode(ssl.PEM_cert_to_DER_cert(open(sys.argv[1] + '/ca.pem').read())).decode()
print(base64.b64encode(json.dumps({"host": "127.0.0.1", "port": 1194, "gatewayID": "gateway.tls.lattice.lab",
    "caDER": ca, "routes": ["10.88.0.0/24"], "rekeySeconds": int(sys.argv[2])}).encode()).decode())
PY
)
quit
open -a "$APP" --args -LatticeCNSA2Certificate "$(base64 < "$W/client.der" | tr -d '\n')" -LatticeCNSA2Lab "$BLOB"
