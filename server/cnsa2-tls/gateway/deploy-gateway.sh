#!/bin/sh
# Operator script, run from the admin Mac: installs a CNSA 2.0 gateway on one concentrator.
#   deploy-gateway.sh <server address> <gateway name, e.g. us-central-1.gw.latticevpn.ai>
# The gateway's key is made on the server and never leaves it. The certificate is requested
# from the signing server through the account API host (us-west-1), which holds the token.
# Only public material (request, certificates) passes through this Mac.
set -eu
HOST=$1; NAME=$2
API_HOST=${API_HOST:-5.78.203.171}
HERE="$(cd "$(dirname "$0")" && pwd)"
D=/etc/openvpn/server/lattice-cnsa2
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
scp -q "$HERE/install-gateway.sh" "root@$HOST:/root/lattice-install-gateway.sh"
ssh "root@$HOST" "bash /root/lattice-install-gateway.sh prepare '$NAME'"
scp -q "$HERE/cnsa2-tls-verify.sh" "$HERE/cnsa2-denylist-sync.sh" "$HERE/cnsa2-gateway-renew.sh" "root@$HOST:$D/"
ssh "root@$HOST" "cat $D/gateway.req" > "$W/gateway.req"
ssh "root@$API_HOST" "python3 /root/lattice-issue.py gateway '$NAME'" < "$W/gateway.req" > "$W/issued.json"
python3 - "$W" <<'PY'
import base64, json, ssl, sys
w = sys.argv[1]; j = json.load(open(w + "/issued.json"))
open(w + "/gateway.der", "wb").write(base64.b64decode(j["certificate"]))
for key, name in (("issuing", "issuing-ca.pem"), ("root", "root-ca.pem")):
    open(w + "/" + name, "w").write(ssl.DER_cert_to_PEM_cert(base64.b64decode(j[key])))
PY
scp -q "$W/gateway.der" "$W/issuing-ca.pem" "$W/root-ca.pem" "root@$HOST:$D/"
ssh "root@$HOST" "bash /root/lattice-install-gateway.sh finish '$NAME'; rm -f /root/lattice-install-gateway.sh"
# Daily renewal check. The key hash it prints must be added to this gateway's entry
# ("key_sha384") in /etc/cloakvpn/cnsa2-gateways.json on the account API host, or renewal is refused.
scp -q "$HERE/install-renewal-timer.sh" "root@$HOST:/root/lattice-install-renewal-timer.sh"
ssh "root@$HOST" "bash /root/lattice-install-renewal-timer.sh; rm -f /root/lattice-install-renewal-timer.sh"
