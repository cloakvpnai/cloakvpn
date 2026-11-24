#!/bin/sh
# Lab only: enrolls through the account API the way the apps will.
#   lab-api-enroll.sh <request.der> <certificate out .der>
# LATTICE_API_URL (default http://127.0.0.1:8088) and LATTICE_ACCOUNT_FILE (a
# file holding the account number; never pass the number on the command line).
set -eu
exec python3 - "$1" "$2" "${LATTICE_API_URL:-http://127.0.0.1:8088}" "${LATTICE_ACCOUNT_FILE:?set LATTICE_ACCOUNT_FILE}" <<'PY'
import base64, json, sys, urllib.error, urllib.request
req, out, url, account_file = sys.argv[1:5]
body = json.dumps({"request": base64.b64encode(open(req, "rb").read()).decode()}).encode()
r = urllib.request.Request(url + "/v1/device/cnsa2/enroll", data=body,
        headers={"Authorization": "Bearer " + open(account_file).read().strip(), "Content-Type": "application/json"})
try:
    with urllib.request.urlopen(r, timeout=40) as f:
        reply = json.loads(f.read())
except urllib.error.HTTPError as e:
    sys.exit("refused: %s %s" % (e.code, e.read().decode().strip()))
open(out, "wb").write(base64.b64decode(reply["certificate"]))
open(out + ".json", "w").write(json.dumps({k: reply[k] for k in ("device", "not_after", "gateways")}))
print("enrolled device %s (id %s) until %s" % (reply["device"]["uid"], reply["device"]["id"], reply["not_after"]))
PY
