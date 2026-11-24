#!/bin/sh
# Renews this gateway's own certificate through the account API, with the key it already has.
#   cnsa2-gateway-renew.sh <api base url> <file holding the internal secret> [force]
# Does nothing unless the certificate expires within 30 days (or "force" is given).
# The key never leaves this server. A new certificate is installed only if it is for this
# key and this name, chains to the Lattice root already trusted here, and expires later
# than the current one. If the service does not come back with it, the old one is restored.
set -eu
URL=$1; SECRET_FILE=$2; FORCE=${3:-}
D=/etc/openvpn/server/lattice-cnsa2
UNIT=openvpn-server@lattice-cnsa2
ROOT_SHA384=38b0bad58ca0da515a9cf6b6c0974d3f4a58375eda398fd78d2539b1a67945f670708d7b8693ffb5725e94d806ae07e2
RENEW_DAYS=30
cd "$D"
NAME=$(openssl x509 -in gateway.pem -noout -ext subjectAltName | sed -n 's/.*DNS:\([^, ]*\).*/\1/p' | head -1)
[ -n "$NAME" ] || { echo "cannot read this gateway's name from its certificate"; exit 1; }
if [ "$FORCE" != force ] && openssl x509 -in gateway.pem -noout -checkend $((RENEW_DAYS * 86400)) >/dev/null; then
  echo "not due: $NAME $(openssl x509 -in gateway.pem -noout -enddate)"; exit 0
fi
umask 077
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
openssl req -new -key gateway.key -subj "/CN=$NAME" -outform DER -out "$W/req.der"
python3 - "$NAME" "$W" <<'PY'
import base64, json, sys
name, w = sys.argv[1], sys.argv[2]
json.dump({"name": name, "request": base64.b64encode(open(w + "/req.der", "rb").read()).decode()}, open(w + "/body.json", "w"))
PY
if ! curl -fsS --max-time 60 -H "Authorization: Bearer $(cat "$SECRET_FILE")" -H "Content-Type: application/json" \
     --data-binary "@$W/body.json" "$URL/v1/internal/cnsa2/gateway-cert" -o "$W/reply.json"; then
  echo "renewal request failed; keeping the current certificate"; exit 1
fi
python3 - "$W" <<'PY'
import base64, json, ssl, sys
w = sys.argv[1]; j = json.load(open(w + "/reply.json"))
open(w + "/new.pem", "w").write(ssl.DER_cert_to_PEM_cert(base64.b64decode(j["certificate"])))
open(w + "/issuing.pem", "w").write(ssl.DER_cert_to_PEM_cert(base64.b64decode(j["issuing"])))
open(w + "/root.der", "wb").write(base64.b64decode(j["root"]))
PY
[ "$(sha384sum < "$W/root.der" | cut -d' ' -f1)" = "$ROOT_SHA384" ] || { echo "reply names a different root; refused"; exit 1; }
[ "$(openssl x509 -in root-ca.pem -outform DER | sha384sum | cut -d' ' -f1)" = "$ROOT_SHA384" ] || { echo "local root is not the Lattice root; refused"; exit 1; }
openssl verify -x509_strict -purpose sslserver -CAfile root-ca.pem -untrusted "$W/issuing.pem" "$W/new.pem" >/dev/null || { echo "new certificate does not verify; refused"; exit 1; }
[ "$(openssl x509 -in "$W/new.pem" -noout -pubkey | sha384sum)" = "$(openssl pkey -in gateway.key -pubout | sha384sum)" ] || { echo "new certificate is not for this server's key; refused"; exit 1; }
openssl x509 -in "$W/new.pem" -noout -ext subjectAltName | grep -q "DNS:$NAME" || { echo "new certificate is not for $NAME; refused"; exit 1; }
old_end=$(date -d "$(openssl x509 -in gateway.pem -noout -enddate | cut -d= -f2)" +%s)
new_end=$(date -d "$(openssl x509 -in "$W/new.pem" -noout -enddate | cut -d= -f2)" +%s)
[ "$new_end" -gt "$old_end" ] || { echo "new certificate does not expire later than the current one; refused"; exit 1; }

cp -p gateway.pem gateway.pem.prev; cp -p issuing-ca.pem issuing-ca.pem.prev; cp -p ca-chain.pem ca-chain.pem.prev
install -m 644 "$W/new.pem" gateway.pem
install -m 644 "$W/issuing.pem" issuing-ca.pem
cat root-ca.pem issuing-ca.pem > ca-chain.pem; chmod 644 ca-chain.pem
systemctl restart "$UNIT"; sleep 4
if [ "$(systemctl is-active "$UNIT")" != active ]; then
  echo "service did not start with the new certificate; restoring the previous one"
  cp -p gateway.pem.prev gateway.pem; cp -p issuing-ca.pem.prev issuing-ca.pem; cp -p ca-chain.pem.prev ca-chain.pem
  systemctl restart "$UNIT"; exit 1
fi
echo "renewed: $NAME serial $(openssl x509 -in gateway.pem -noout -serial | cut -d= -f2) $(openssl x509 -in gateway.pem -noout -enddate)"
