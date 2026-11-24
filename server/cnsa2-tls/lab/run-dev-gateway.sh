#!/bin/sh
# Persistent TLS 1.3 lab gateway, reachable on the Mac at UDP 1194 (all
# interfaces) through relay.py, because Colima does not forward UDP.
#   GATEWAY_RENEG=seconds   how often the gateway itself asks for new keys (default 0: the device drives it)
#   LAB_CA=local (default)  throwaway lab authority in pki/ (run run-lab.sh once first)
#   LAB_CA=kms              the real root and issuing authority in AWS KMS: the gateway makes its own
#                           key in pki-kms/ and gets its certificate from the signing service
#                           (../../cnsa2-ca/run-lab-service.sh must be running)
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; IMG=lattice-cnsa2-tls-lab
CA_DIR="$HERE/../../cnsa2-ca"; GATEWAY_NAME="${GATEWAY_NAME:-lab.gw.latticevpn.ai}"
if [ "${LAB_CA:-local}" = kms ]; then
  PKI="$HERE/pki-kms"; mkdir -p "$PKI"; CAFILE=ca-chain.pem; EXTRA="extra-certs /pki/issuing-ca.pem"
  cat "$CA_DIR/certs/root-ca.pem" "$CA_DIR/certs/issuing-ca.pem" > "$PKI/ca-chain.pem"
  cp "$CA_DIR/certs/issuing-ca.pem" "$PKI/issuing-ca.pem"
  if [ ! -f "$PKI/gateway.pem" ] || ! openssl x509 -in "$PKI/gateway.pem" -noout -checkend 604800 >/dev/null 2>&1; then
    docker run --rm -v "$PKI:/pki" $IMG sh -euc "
      [ -f /pki/gateway.key ] || openssl genpkey -algorithm ML-DSA-87 -out /pki/gateway.key
      openssl req -new -key /pki/gateway.key -subj /CN=$GATEWAY_NAME -outform DER -out /pki/gateway.req"
    "$CA_DIR/lab-issue.sh" gateway "$GATEWAY_NAME" "$PKI/gateway.req" "$PKI/gateway.der"
    openssl x509 -inform DER -in "$PKI/gateway.der" -out "$PKI/gateway.pem"
  fi
else
  PKI="$HERE/pki"; CAFILE=ca.pem; EXTRA=""
  [ -f "$PKI/ca.pem" ] || { echo "run run-lab.sh first"; exit 1; }
fi
cat > "$PKI/dev-server.conf" <<CONF
dev tun
proto udp
mode server
tls-server
dh none
topology subnet
server 10.88.0.0 255.255.255.0
tls-version-min 1.3
tls-ciphersuites TLS_AES_256_GCM_SHA384
tls-groups MLKEM1024
data-ciphers AES-256-GCM
data-ciphers-fallback AES-256-GCM
auth SHA384
reneg-sec ${GATEWAY_RENEG:-0}
ca /pki/$CAFILE
cert /pki/gateway.pem
key /pki/gateway.key
$EXTRA
remote-cert-tls client
keepalive 10 60
duplicate-cn
verb 4
CONF
docker rm -f tlsgw tlscl tls-relay >/dev/null 2>&1 || true
docker network create cnsa2-tls >/dev/null 2>&1 || true
docker run -d --name tlsgw --cap-add NET_ADMIN --device /dev/net/tun --network cnsa2-tls -v "$PKI:/pki:ro" $IMG \
  openvpn --config /pki/dev-server.conf >/dev/null
# the relay needs python3, which the IPsec lab image has
docker run -d --name tls-relay --network cnsa2-tls -p 11194:11194 -v "$HERE/relay.py:/relay.py:ro" lattice-cnsa2-lab:master \
  python3 /relay.py gateway 11194 tlsgw:1194 >/dev/null
pkill -f "relay.py host 127.0.0.1:11194" 2>/dev/null || true
nohup python3 "$HERE/relay.py" host 127.0.0.1:11194 1194 0.0.0.0 >/tmp/tls-relay.log 2>&1 &
sleep 2
docker ps --format '{{.Names}} {{.Status}}' | grep -E 'tlsgw|tls-relay'
