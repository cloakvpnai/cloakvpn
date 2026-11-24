#!/bin/bash
# Installs a CNSA 2.0 gateway next to WireGuard on a Lattice concentrator
# (Ubuntu 26.04: stock OpenVPN 2.7 + OpenSSL 3.5). Run on the server as root.
#
#   install-gateway.sh prepare <gateway name>      # packages, key, certificate request (prints nothing secret)
#   install-gateway.sh finish  <gateway name>      # expects gateway.der, issuing-ca.pem, root-ca.pem in $D; configures and starts
#
# WireGuard, the key daemon and the provisioning service are not touched.
# Adds: one service, UDP 1194 in ufw, one forward rule and one NAT rule for 10.88.0.0/24.
set -eu
MODE=$1; NAME=$2
D=/etc/openvpn/server/lattice-cnsa2
ROOT_SHA384=38b0bad58ca0da515a9cf6b6c0974d3f4a58375eda398fd78d2539b1a67945f670708d7b8693ffb5725e94d806ae07e2
WAN=$(ip -o -4 route show default | awk '{print $5}' | head -1)

if [ "$MODE" = prepare ]; then
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends openvpn >/dev/null
  systemctl disable -q --now openvpn.service 2>/dev/null || true
  install -d -m 700 "$D"
  if [ ! -f "$D/gateway.key" ]; then (umask 077; openssl genpkey -algorithm ML-DSA-87 -out "$D/gateway.key"); fi
  openssl req -new -key "$D/gateway.key" -subj "/CN=$NAME" -outform DER -out "$D/gateway.req"
  echo "openvpn $(openvpn --version | head -1 | cut -d' ' -f2), key $(openssl pkey -in "$D/gateway.key" -noout -text 2>/dev/null | head -1), request $(stat -c %s "$D/gateway.req") bytes"
  exit 0
fi

[ "$MODE" = finish ] || { echo "unknown mode"; exit 1; }
cd "$D"
# The root must be the Lattice root, the chain must verify, and the certificate must be for this key and name.
[ "$(openssl x509 -in root-ca.pem -outform DER | sha384sum | cut -d' ' -f1)" = "$ROOT_SHA384" ] || { echo "root certificate is not the Lattice root"; exit 1; }
openssl x509 -inform DER -in gateway.der -out gateway.pem
openssl verify -x509_strict -purpose sslserver -CAfile root-ca.pem -untrusted issuing-ca.pem gateway.pem >/dev/null || { echo "gateway certificate does not verify"; exit 1; }
[ "$(openssl x509 -in gateway.pem -noout -pubkey | sha384sum)" = "$(openssl pkey -in gateway.key -pubout | sha384sum)" ] || { echo "certificate is not for this server's key"; exit 1; }
openssl x509 -in gateway.pem -noout -ext subjectAltName | grep -q "DNS:$NAME" || { echo "certificate is not for $NAME"; exit 1; }
cat root-ca.pem issuing-ca.pem > ca-chain.pem
chmod 600 gateway.key; chmod 644 gateway.pem issuing-ca.pem root-ca.pem ca-chain.pem; rm -f gateway.req gateway.der
chmod 755 "$D" cnsa2-tls-verify.sh cnsa2-denylist-sync.sh
[ -f denylist ] || printf '# end 0\n' > denylist; chmod 644 denylist

cat > /etc/openvpn/server/lattice-cnsa2.conf <<CONF
# Lattice VPN CNSA 2.0 gateway. TLS 1.3 only, one suite, one group, ML-DSA-87 certificates.
port 1194
proto udp
dev tun-cnsa2
dev-type tun
mode server
tls-server
dh none
topology subnet
server 10.88.0.0 255.255.255.0
# full tunnel: all IPv4 traffic and DNS go through the gateway
push "redirect-gateway def1"
push "dhcp-option DNS 9.9.9.9"
push "dhcp-option DNS 149.112.112.112"
tls-version-min 1.3
tls-ciphersuites TLS_AES_256_GCM_SHA384
tls-groups MLKEM1024
data-ciphers AES-256-GCM
data-ciphers-fallback AES-256-GCM
auth SHA384
reneg-sec 3600
ca $D/ca-chain.pem
cert $D/gateway.pem
key $D/gateway.key
extra-certs $D/issuing-ca.pem
remote-cert-tls client
keepalive 10 60
script-security 2
tls-verify "$D/cnsa2-tls-verify.sh $D/denylist"
user nobody
group nogroup
persist-key
persist-tun
# verb 0: only fatal errors are logged, so client addresses never reach the journal.
verb 0
CONF
chmod 600 /etc/openvpn/server/lattice-cnsa2.conf

# Forwarding and NAT for the CNSA 2.0 tunnel range live with the service, like wg0's PostUp rules.
install -d /etc/systemd/system/openvpn-server@lattice-cnsa2.service.d
cat > /etc/systemd/system/openvpn-server@lattice-cnsa2.service.d/lattice-nat.conf <<UNIT
[Service]
ExecStartPre=/bin/sh -c 'iptables -t nat -C POSTROUTING -s 10.88.0.0/24 -o $WAN -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s 10.88.0.0/24 -o $WAN -j MASQUERADE'
ExecStartPre=/bin/sh -c 'iptables -t mangle -C FORWARD -i tun-cnsa2 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -t mangle -A FORWARD -i tun-cnsa2 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu'
ExecStartPre=/bin/sh -c 'iptables -t mangle -C FORWARD -o tun-cnsa2 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -t mangle -A FORWARD -o tun-cnsa2 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu'
ExecStopPost=-/bin/sh -c 'iptables -t nat -D POSTROUTING -s 10.88.0.0/24 -o $WAN -j MASQUERADE'
ExecStopPost=-/bin/sh -c 'iptables -t mangle -D FORWARD -i tun-cnsa2 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu'
ExecStopPost=-/bin/sh -c 'iptables -t mangle -D FORWARD -o tun-cnsa2 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu'
UNIT

# Deny list from the account API every 3 minutes.
cat > /etc/systemd/system/lattice-cnsa2-denylist.service <<UNIT
[Unit]
Description=Lattice CNSA 2.0 deny list sync
[Service]
Type=oneshot
EnvironmentFile=/etc/cloakvpn/regionsvc.env
ExecStart=/bin/sh -c 'umask 077; printf %%s "\$REGION_INTERNAL_SECRET" > /run/lattice-cnsa2-secret; $D/cnsa2-denylist-sync.sh https://api.latticevpn.ai /run/lattice-cnsa2-secret $D/denylist; rc=\$?; rm -f /run/lattice-cnsa2-secret; exit \$rc'
UNIT
cat > /etc/systemd/system/lattice-cnsa2-denylist.timer <<UNIT
[Unit]
Description=Lattice CNSA 2.0 deny list sync every 3 minutes
[Timer]
OnBootSec=30
OnUnitActiveSec=180
[Install]
WantedBy=timers.target
UNIT

B=/var/backups/lattice-cnsa2-gateway-$(date -u +%Y%m%d); mkdir -p $B; chmod 700 $B
[ -f $B/iptables.rules ] || { iptables-save > $B/iptables.rules; ufw status numbered > $B/ufw-status.txt; }
ufw allow 1194/udp comment 'Lattice CNSA 2.0' >/dev/null
ufw route allow in on tun-cnsa2 out on "$WAN" >/dev/null
systemctl daemon-reload
systemctl start lattice-cnsa2-denylist.service && echo "deny list: $(tail -1 $D/denylist)"
systemctl enable -q --now lattice-cnsa2-denylist.timer
systemctl enable -q --now openvpn-server@lattice-cnsa2
sleep 4
echo "gateway: $(systemctl is-active openvpn-server@lattice-cnsa2) | listening udp 1194: $(ss -lunH | grep -c ':1194 ') | tunnel: $(ip -4 -o addr show tun-cnsa2 | awk '{print $4}')"
journalctl -u openvpn-server@lattice-cnsa2 --no-pager -n 6 | grep -iE "error|Initialization|fatal|cannot|denied" | sed 's/^.*openvpn\[[0-9]*\]: //' | cut -c1-140
echo "nat rules for 10.88: $(iptables -t nat -S POSTROUTING | grep -c '10.88.0.0/24') | wg0 nat still present: $(iptables -t nat -S POSTROUTING | grep -c '10.99.0.0/24')"
echo "untouched: wg0 $(systemctl is-active wg-quick@wg0), peers $(wg show wg0 | grep -c '^peer'), regionsvc $(systemctl is-active regionsvc), rpd $(systemctl is-active cloak-rpd), healthz $(curl -s -o /dev/null -w %{http_code} --max-time 5 http://127.0.0.1:8090/healthz)"
