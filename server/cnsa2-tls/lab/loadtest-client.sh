#!/bin/sh
# Load generator: N OpenVPN 2.7 clients with no tun device (dev null), lab certificates.
# Usage: loadtest-client.sh start <gateway ip> <count> <per-second> [reneg-sec] | count | stop
set -eu
D=/root/cnsa2-loadtest
case "$1" in
start)
  GW=$2; N=$3; RATE=$4; RENEG=${5:-3600}
  mkdir -p $D/logs
  cat > $D/client.conf <<EOF
client
dev null
proto udp
remote $GW 11940
nobind
tls-version-min 1.3
tls-ciphersuites TLS_AES_256_GCM_SHA384
tls-groups MLKEM1024
data-ciphers AES-256-GCM
data-ciphers-fallback AES-256-GCM
auth SHA384
reneg-sec $RENEG
ca $D/ca.pem
cert $D/client.pem
key $D/client.key
remote-cert-tls server
verify-x509-name gateway.tls.lattice.lab name
ifconfig-noexec
route-noexec
connect-retry 2 10
verb 1
EOF
  i=0
  while [ $i -lt "$N" ]; do
    j=0
    while [ $j -lt "$RATE" ] && [ $i -lt "$N" ]; do
      openvpn --config $D/client.conf --log $D/logs/c$i.log --writepid $D/logs/c$i.pid --daemon lt-client-$i
      i=$((i+1)); j=$((j+1))
    done
    sleep 1
  done
  echo started $i
  ;;
count)
  echo "processes $(pgrep -c -f 'lt-client-' || true) completed $(grep -l 'Initialization Sequence Completed' $D/logs/*.log 2>/dev/null | wc -l) errors $(grep -il 'error\|failed' $D/logs/*.log 2>/dev/null | wc -l)"
  free -m | sed -n 2p
  ;;
stop)
  pkill -f 'lt-client-' || true
  sleep 2
  echo "left $(pgrep -c -f 'lt-client-' || true)"
  rm -rf $D/logs
  ;;
esac
