#!/bin/sh
# Brings up a gateway and a client container, completes a CNSA 2.0 handshake,
# passes traffic, forces re-keys, and prints what was negotiated.
#   ./run-lab.sh [image] [keytype]
#   image:   lattice-cnsa2-lab:master (default) or lattice-cnsa2-lab:latest
#   keytype: mldsa87 (default, needs the master image) or ecdsa384
set -eu
IMG="${1:-lattice-cnsa2-lab:master}"
KT="${2:-mldsa87}"
HERE="$(cd "$(dirname "$0")" && pwd)"
case "$KT" in
  mldsa87)  GEN="--type mldsa87" ;;
  ecdsa384) GEN="--type ecdsa --size 384" ;;
  *) echo "unknown key type $KT" >&2; exit 2 ;;
esac
docker rm -f cnsa2-gw cnsa2-client >/dev/null 2>&1 || true
docker network rm cnsa2-lab >/dev/null 2>&1 || true
docker volume rm cnsa2-pki >/dev/null 2>&1 || true
docker network create cnsa2-lab >/dev/null
docker volume create cnsa2-pki >/dev/null

echo "== PKI ($KT)"
docker run --rm -v cnsa2-pki:/pki "$IMG" sh -euc "
  cd /pki
  pki --gen $GEN --outform pem > ca.key
  pki --self --ca --lifetime 3650 --in ca.key --dn 'C=US, O=Lattice Lab, CN=Lattice Lab Root CA' --outform pem > ca.pem
  for n in gateway:gw.lattice.lab client:device1.lattice.lab; do
    f=\${n%%:*}; id=\${n##*:}
    pki --gen $GEN --outform pem > \$f.key
    pki --pub --in \$f.key | pki --issue --lifetime 365 --cacert ca.pem --cakey ca.key --dn \"C=US, O=Lattice Lab, CN=\$id\" --san \$id --outform pem > \$f.pem
  done
  openssl x509 -in gateway.pem -noout -text | grep -E 'Signature Algorithm|Public Key Algorithm' | sort -u
"
start() { # name conf cert
  docker run -d --name "$1" --network cnsa2-lab --cap-add NET_ADMIN \
    -v cnsa2-pki:/pki:ro -v "$HERE/$2:/etc/swanctl/swanctl.conf:ro" "$IMG" sh -c "
      cp /pki/ca.pem /etc/swanctl/x509ca/ && cp /pki/$3.pem /etc/swanctl/x509/ && cp /pki/$3.key /etc/swanctl/private/
      # ML-DSA-87 certificates and signatures make IKE_AUTH about 13 KB,
      # above strongSwan's 10 KB default for a reassembled message.
      printf 'charon {\\n  max_packet = 30000\\n}\\n' > /etc/strongswan.d/lattice.conf
      /usr/libexec/ipsec/charon > /var/log/charon.log 2>&1 &
      sleep 2; swanctl --load-all >/dev/null 2>&1; sleep infinity" >/dev/null
}
start cnsa2-gw gateway.swanctl.conf gateway
docker exec cnsa2-gw ip addr add 10.99.0.1/24 dev lo
start cnsa2-client client.swanctl.conf client
sleep 4

echo "== Handshake"
docker exec cnsa2-client swanctl --initiate --child net 2>&1 | grep -E 'selected proposal|authentication of|established|failed|no proposal|IKE_INTERMEDIATE|error' || true
echo "== Negotiated (client view)"
docker exec cnsa2-client swanctl --list-sas
echo "== Traffic through the tunnel"
docker exec cnsa2-client ping -c 3 -W 2 10.99.0.1 | tail -2
echo "== Re-key Child SA, then IKE SA"
docker exec cnsa2-client swanctl --rekey --child net 2>&1 | tail -1
sleep 2
docker exec cnsa2-client swanctl --rekey --ike cnsa2 2>&1 | tail -1
sleep 3
docker exec cnsa2-client swanctl --list-sas
docker exec cnsa2-client ping -c 2 -W 2 10.99.0.1 | tail -2
echo "== Gateway log: proposals and authentication"
docker exec cnsa2-gw grep -E 'selected proposal|authentication of .* with|CHILD_SA .* established|rekey' /var/log/charon.log | sed 's/^[^]]*] //' | sort | uniq -c | sort -rn | head -12
echo "== Negative test: a client offering WireGuard-class algorithms is refused"
docker exec cnsa2-client sh -c "sed 's/aes256gcm16-prfsha384-ecp384-ke1_mlkem1024/chacha20poly1305-prfsha256-x25519/' /etc/swanctl/swanctl.conf > /etc/swanctl/bad.conf && swanctl --terminate --ike cnsa2 >/dev/null 2>&1; swanctl --load-conns --file /etc/swanctl/bad.conf >/dev/null 2>&1; swanctl --initiate --child net 2>&1 | grep -E 'selected proposal|NO_PROPOSAL_CHOSEN|no proposal|failed|established' | head -3" || true
