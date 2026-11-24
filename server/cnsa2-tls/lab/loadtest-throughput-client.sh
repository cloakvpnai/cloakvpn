#!/bin/sh
# One real tunnel client for the throughput test. Usage: lt-throughput-client.sh <gateway ip>
set -eu
D=/root/cnsa2-loadtest
GW=$1
cat > $D/client.conf <<EOF
client
dev tun-lt
dev-type tun
proto udp
remote $GW 11940
nobind
tls-version-min 1.3
tls-ciphersuites TLS_AES_256_GCM_SHA384
tls-groups MLKEM1024
data-ciphers AES-256-GCM
data-ciphers-fallback AES-256-GCM
auth SHA384
ca $D/ca.pem
cert $D/client.pem
key $D/client.key
remote-cert-tls server
verify-x509-name gateway.tls.lattice.lab name
verb 1
EOF
openvpn --config $D/client.conf --log $D/client.log --writepid $D/client.pid --daemon lt-throughput
sleep 6
grep -o "DCO device.*opened\|Initialization Sequence Completed" $D/client.log | head -2
ip -br -4 addr show tun-lt | tr -s ' '
ping -c 3 -q 10.89.0.1 | tail -1
for run in 1 2; do
  vmstat 1 12 > $D/vm.txt &
  echo "tunnel run $run: $(curl -s -o /dev/null -m 12 -w '%{speed_download}' http://10.89.0.1:8000/zero || true) bytes/s"
  wait
  awk 'NR>3 {us+=$13; sy+=$14; id+=$15; n++} END {printf "  client cpu avg: us %.0f sy %.0f idle %.0f\n", us/n, sy/n, id/n}' $D/vm.txt
done
echo "direct, no tunnel: $(curl -s -o /dev/null -m 12 -w '%{speed_download}' http://$GW:11941/zero || true) bytes/s"
kill "$(cat $D/client.pid)" || true
