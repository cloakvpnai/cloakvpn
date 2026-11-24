#!/bin/sh
# Widen the CNSA 2.0 gateway address block from 10.88.0.0/24 (253 clients) to 10.88.0.0/19
# (8,190 addresses) and allow up to 5,000 clients. Run as root on a gateway. Safe to run twice.
set -eu
C=/etc/openvpn/server/lattice-cnsa2.conf
DD=/etc/systemd/system/openvpn-server@lattice-cnsa2.service.d
if grep -q '^server 10.88.0.0 255.255.224.0$' "$C" && grep -q '^max-clients 5000$' "$C" && ! grep -rq '10.88.0.0/24' "$DD"; then
  echo "already widened"
else
  cp -p "$C" "$C.bak-20261124g"
  for f in "$DD"/*.conf; do cp -p "$f" "/root/$(basename "$f").lattice-cnsa2-dropin.bak-20261124g"; done
  sed -i 's/^server 10\.88\.0\.0 255\.255\.255\.0$/server 10.88.0.0 255.255.224.0/' "$C"
  grep -q '^max-clients ' "$C" || printf '\n# Address block is 10.88.0.0/19; the default limit of 1,024 clients would cap it first.\nmax-clients 5000\n' >> "$C"
  sed -i 's#10\.88\.0\.0/24#10.88.0.0/19#g' "$DD"/*.conf
  systemctl daemon-reload
  systemctl restart openvpn-server@lattice-cnsa2
  sleep 3
  WAN=$(ip route show default | awk '{print $5; exit}')
  while iptables -t nat -C POSTROUTING -s 10.88.0.0/24 -o "$WAN" -j MASQUERADE 2>/dev/null; do
    iptables -t nat -D POSTROUTING -s 10.88.0.0/24 -o "$WAN" -j MASQUERADE
  done
fi
echo "service: $(systemctl is-active openvpn-server@lattice-cnsa2)"
echo "tun: $(ip -br -4 addr show tun-cnsa2 | tr -s ' ')"
echo "nat /19: $(iptables -t nat -S POSTROUTING | grep -c '10.88.0.0/19')  nat /24 left: $(iptables -t nat -S POSTROUTING | grep -c '10.88.0.0/24')"
echo "conf: $(grep -c '^server 10.88.0.0 255.255.224.0$' "$C") $(grep '^max-clients' "$C")"
echo "wireguard up: $(wg show wg0 2>/dev/null | grep -c 'listening port')"
