#!/bin/sh
# Temporary CNSA 2.0 load-test gateway. Lab certificates, separate port and tun, same crypto and
# tls-verify hook as production. Usage: loadtest-server.sh start <generator ip> | stop <generator ip>
set -eu
D=/root/cnsa2-loadtest
case "$1" in
start)
  cp /etc/openvpn/server/lattice-cnsa2/cnsa2-tls-verify.sh $D/verify.sh; chmod 755 $D/verify.sh
  cp /etc/openvpn/server/lattice-cnsa2/denylist $D/denylist; chmod 644 $D/denylist; chmod 755 $D
  cat > $D/server.conf <<EOF
port 11940
proto udp
dev tun-load
dev-type tun
mode server
tls-server
dh none
topology subnet
server 10.89.0.0 255.255.0.0
max-clients 2000
duplicate-cn
tls-version-min 1.3
tls-ciphersuites TLS_AES_256_GCM_SHA384
tls-groups MLKEM1024
data-ciphers AES-256-GCM
data-ciphers-fallback AES-256-GCM
auth SHA384
reneg-sec ${RENEG:-3600}
ca $D/ca.pem
cert $D/gateway.pem
key $D/gateway.key
remote-cert-tls client
keepalive 10 60
script-security 2
tls-verify "$D/verify.sh $D/denylist"
status $D/status 2
writepid $D/pid
verb 1
log $D/server.log
EOF
  ufw allow from "$2" to any port 11940 proto udp comment "temporary CNSA2 load test" >/dev/null
  openvpn --config $D/server.conf --daemon lattice-loadtest
  sleep 2; cat $D/pid; tail -2 $D/server.log | cut -c1-120
  ;;
stop)
  [ -f $D/pid ] && kill "$(cat $D/pid)" 2>/dev/null || true
  sleep 2
  ufw delete allow from "$2" to any port 11940 proto udp >/dev/null 2>&1 || true
  ufw status | grep -c 11940 || true
  ip link show tun-load 2>/dev/null | head -1 || echo "tun-load gone"
  ;;
esac
