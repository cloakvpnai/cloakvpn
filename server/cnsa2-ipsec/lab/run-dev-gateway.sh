#!/bin/sh
# Persistent lab gateway reachable at 127.0.0.1 UDP 4500 (through relay.py,
# because Colima does not forward UDP) for developing the
# app-side IKEv2 engine. ML-DSA-87 PKI is written to ./pki-dev (git-ignored).
# Lab only: built from unreleased strongSwan code.
set -eu
IMG="${1:-lattice-cnsa2-lab:master}"
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$HERE/pki-dev"
if [ ! -f "$HERE/pki-dev/ca.pem" ]; then
  docker run --rm -v "$HERE/pki-dev:/pki" "$IMG" sh -euc "
    cd /pki
    pki --gen --type mldsa87 --outform pem > ca.key
    pki --self --ca --lifetime 3650 --in ca.key --dn 'C=US, O=Lattice Lab, CN=Lattice Lab Root CA' --outform pem > ca.pem
    for n in gateway:gw.lattice.lab client:device1.lattice.lab; do
      f=\${n%%:*}; id=\${n##*:}
      pki --gen --type mldsa87 --outform pem > \$f.key
      pki --pub --in \$f.key | pki --issue --lifetime 365 --cacert ca.pem --cakey ca.key --dn \"C=US, O=Lattice Lab, CN=\$id\" --san \$id --outform pem > \$f.pem
      openssl x509 -in \$f.pem -outform der -out \$f.der
      openssl pkey -in \$f.key -outform der -out \$f.key.der
    done
    openssl x509 -in ca.pem -outform der -out ca.der"
fi
docker rm -f cnsa2-devgw cnsa2-relay >/dev/null 2>&1 || true
docker network create cnsa2-dev >/dev/null 2>&1 || true
docker run -d --name cnsa2-devgw --network cnsa2-dev --cap-add NET_ADMIN \
  -v "$HERE/pki-dev:/pki:ro" -v "$HERE/gateway.swanctl.conf:/etc/swanctl/swanctl.conf:ro" "$IMG" sh -c "
    cp /pki/ca.pem /etc/swanctl/x509ca/ && cp /pki/gateway.pem /etc/swanctl/x509/ && cp /pki/gateway.key /etc/swanctl/private/
    printf 'charon {\\n  max_packet = 30000\\n  filelog {\\n    stderr {\\n      default = 1\\n      ike = 2\\n      enc = 2\\n      cfg = 2\\n    }\\n  }\\n}\\n' > /etc/strongswan.d/lattice.conf
    ip addr add 10.99.0.1/24 dev lo
    /usr/libexec/ipsec/charon > /var/log/charon.log 2>&1 &
    sleep 2; swanctl --load-all >/dev/null 2>&1; sleep infinity" >/dev/null
# The relay runs in its own container so the gateway sees the client at a
# different address, as it would across a real network.
docker run -d --name cnsa2-relay --network cnsa2-dev -p 14500:14500 -v "$HERE/relay.py:/relay.py:ro" "$IMG" \
  python3 /relay.py gateway 14500 cnsa2-devgw:4500 >/dev/null
sleep 4
pkill -f "relay.py host" 2>/dev/null || true
python3 "$HERE/relay.py" host 127.0.0.1:14500 4500 >/dev/null 2>&1 &
docker exec cnsa2-devgw swanctl --list-conns | head -2
