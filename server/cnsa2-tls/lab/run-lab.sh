#!/bin/sh
# CNSA 2.0 TLS 1.3 lab: OpenVPN 2.6 + OpenSSL 3.5 from Debian 13, nothing built from source.
# TLS 1.3 only, TLS_AES_256_GCM_SHA384, key exchange ML-KEM-1024, ML-DSA-87 certificates
# both ways, data channel AES-256-GCM, a fresh handshake (new ML-KEM-1024 keys) every 60 s.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; IMG=lattice-cnsa2-tls-lab
mkdir -p "$HERE/pki"
if [ ! -f "$HERE/pki/ca.pem" ]; then
  docker run --rm -v "$HERE/pki:/pki" $IMG sh -euc '
    cd /pki
    openssl genpkey -algorithm ML-DSA-87 -out ca.key
    openssl req -x509 -new -key ca.key -days 3650 -subj "/C=US/O=Lattice Lab/CN=Lattice TLS Lab Root CA" \
      -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" -out ca.pem
    for n in gateway:serverAuth client:clientAuth; do
      f=${n%%:*}; eku=${n##*:}
      openssl genpkey -algorithm ML-DSA-87 -out $f.key
      openssl req -new -key $f.key -subj "/C=US/O=Lattice Lab/CN=$f.tls.lattice.lab" -out $f.csr
      printf "basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=$eku\nsubjectAltName=DNS:$f.tls.lattice.lab\n" > $f.ext
      openssl x509 -req -in $f.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 365 -extfile $f.ext -out $f.pem
    done'
fi
COMMON='dev tun
proto udp
tls-version-min 1.3
tls-ciphersuites TLS_AES_256_GCM_SHA384
tls-groups MLKEM1024
data-ciphers AES-256-GCM
data-ciphers-fallback AES-256-GCM
auth SHA384
reneg-sec 60
ca /pki/ca.pem
verb 4'
printf '%s\n' "$COMMON" 'mode server' 'tls-server' 'dh none' 'topology subnet' 'server 10.88.0.0 255.255.255.0' \
  'cert /pki/gateway.pem' 'key /pki/gateway.key' 'remote-cert-tls client' 'keepalive 10 60' > "$HERE/pki/server.conf"
printf '%s\n' "$COMMON" 'client' 'remote tlsgw 1194' 'nobind' 'cert /pki/client.pem' 'key /pki/client.key' \
  'remote-cert-tls server' 'verify-x509-name gateway.tls.lattice.lab name' > "$HERE/pki/client.conf"
docker rm -f tlsgw tlscl >/dev/null 2>&1 || true
docker network create cnsa2-tls >/dev/null 2>&1 || true
R="--cap-add NET_ADMIN --device /dev/net/tun --network cnsa2-tls -v $HERE/pki:/pki:ro"
docker run -d --name tlsgw $R $IMG openvpn --config /pki/server.conf >/dev/null
sleep 2
docker run -d --name tlscl $R $IMG openvpn --config /pki/client.conf >/dev/null
