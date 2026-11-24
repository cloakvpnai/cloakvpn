#!/bin/sh
# Carry IPv6 through a CNSA 2.0 gateway. Clients get an address from fd42:88::/64 inside the
# tunnel and leave through this server's public IPv6 address (NAT, the same way IPv4 does).
# Run as root on a gateway. Safe to run twice. Does nothing on a server without public IPv6.
set -eu
C=/etc/openvpn/server/lattice-cnsa2.conf
DD=/etc/systemd/system/openvpn-server@lattice-cnsa2.service.d
WAN=$(ip route show default | awk '{print $5; exit}')
if [ -z "$(ip -6 addr show dev "$WAN" scope global | grep inet6 || true)" ] || ! ping -6 -c 2 -W 2 -q 2606:4700:4700::1111 >/dev/null 2>&1; then
  echo "no working public IPv6 on this server; nothing changed"
  exit 3
fi
if grep -q '^server-ipv6 fd42:88::/64$' "$C" && [ -f "$DD/lattice-nat6.conf" ]; then
  echo "already enabled"
else
  cp -p "$C" "$C.bak-20261124h"
  grep -q '^server-ipv6 ' "$C" || printf '\n# IPv6 inside the tunnel. Apps that understand it get an address and send IPv6 through\n# the tunnel; it leaves from this server'"'"'s public IPv6 address.\nserver-ipv6 fd42:88::/64\npush "route-ipv6 2000::/3"\n' >> "$C"
  cat > "$DD/lattice-nat6.conf" <<EOF
[Service]
ExecStartPre=/bin/sh -c 'ip6tables -t nat -C POSTROUTING -s fd42:88::/64 -o $WAN -j MASQUERADE 2>/dev/null || ip6tables -t nat -A POSTROUTING -s fd42:88::/64 -o $WAN -j MASQUERADE'
ExecStartPre=/bin/sh -c 'ip6tables -t mangle -C FORWARD -i tun-cnsa2 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || ip6tables -t mangle -A FORWARD -i tun-cnsa2 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu'
ExecStartPre=/bin/sh -c 'ip6tables -t mangle -C FORWARD -o tun-cnsa2 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || ip6tables -t mangle -A FORWARD -o tun-cnsa2 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu'
ExecStopPost=-/bin/sh -c 'ip6tables -t nat -D POSTROUTING -s fd42:88::/64 -o $WAN -j MASQUERADE'
ExecStopPost=-/bin/sh -c 'ip6tables -t mangle -D FORWARD -i tun-cnsa2 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu'
ExecStopPost=-/bin/sh -c 'ip6tables -t mangle -D FORWARD -o tun-cnsa2 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu'
EOF
  sysctl -q -w net.ipv6.conf.all.forwarding=1
  systemctl daemon-reload
  systemctl restart openvpn-server@lattice-cnsa2
  sleep 3
fi
echo "service: $(systemctl is-active openvpn-server@lattice-cnsa2)"
echo "tun v6: $(ip -6 -br addr show dev tun-cnsa2 scope global | tr -s ' ')"
echo "nat66: $(ip6tables -t nat -S POSTROUTING | grep -c 'fd42:88::/64')  forward rule: $(ip6tables -S ufw6-user-forward 2>/dev/null | grep -c 'tun-cnsa2')"
echo "wireguard up: $(wg show wg0 2>/dev/null | grep -c 'listening port')"
