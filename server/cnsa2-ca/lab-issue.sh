#!/bin/sh
# Lab only: plays the account API. Sends a certificate request to the signing
# service and writes the certificate it returns.
#   lab-issue.sh <device|gateway> <name> <request.der> <certificate out .der>
set -eu
exec python3 - "$1" "$2" "$3" "$4" "${LATTICE_CA_URL:-http://127.0.0.1:8087}" "${LATTICE_CA_TOKEN_FILE:-$HOME/.lattice-ca-lab-token}" <<'PY'
import base64, json, sys, urllib.error, urllib.request
kind, name, req, out, url, token_file = sys.argv[1:7]
body = json.dumps({"kind": kind, "name": name, "request": base64.b64encode(open(req, "rb").read()).decode()}).encode()
r = urllib.request.Request(url + "/v1/issue", data=body,
                           headers={"Authorization": "Bearer " + open(token_file).read().strip()})
try:
    with urllib.request.urlopen(r, timeout=30) as f:
        reply = json.loads(f.read())
except urllib.error.HTTPError as e:
    sys.exit("refused: %s %s" % (e.code, e.read().decode()))
with open(out, "wb") as f:
    f.write(base64.b64decode(reply["certificate"]))
print("issued %s %s serial %s until %s" % (kind, name, reply["serial"], reply["notAfter"]))
PY
