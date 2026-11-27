#!/bin/sh
# Adds a second way in to a CNSA 2.0 gateway: the same tunnel over TCP 443, for networks that
# block UDP 1194 (hotels, schools, offices). Run as root on a gateway. Safe to run twice.
#
#   add-tcp443.sh <second IPv4>   # the usual case: the server's web server already holds 443
#   add-tcp443.sh                 # listen on TCP 443 directly, for a server where it is free
#   add-tcp443.sh 8443            # listen on another port directly
#
# With a second IPv4 address: every gateway runs Caddy on 443 for the region service, on all
# addresses. So the tunnel listens on 8443, and one firewall rule sends connections that arrive
# at the second address on 443 to it. Apps connect to <second address>:443. Caddy is not touched
# and keeps 443 on the first address. The second address must already be assigned to this
# server at the provider; the script adds it to the network interface if the system has not.
#
# What it adds: one more OpenVPN service that shares the gateway's key, certificate, deny list
# and every cryptographic setting with the UDP one. Only the transport differs.
#   service   openvpn-server@lattice-cnsa2-tcp, interface tun-cnsa2t
#   addresses 10.88.32.0/19 (and fd42:89::/64 where the UDP gateway carries IPv6)
#   firewall  the port in ufw, one forward rule, NAT for the new block
#   limit     1,000 clients, to leave memory for the UDP gateway on small servers
# The UDP gateway, WireGuard and everything else are not changed or restarted.
# It refuses to run if something else is already listening on the port.
#
# Hetzner servers also need an inbound TCP rule for the port in the cloud firewall.
#
# Take it out again:
#   systemctl disable --now openvpn-server@lattice-cnsa2-tcp
#   rm -r /etc/openvpn/server/lattice-cnsa2-tcp.conf /etc/systemd/system/openvpn-server@lattice-cnsa2-tcp.service.d
#   ufw delete allow <port>/tcp; ufw route delete allow in on tun-cnsa2t out on <wan interface>; systemctl daemon-reload
set -eu
ADDR=
case "${1:-}" in
  *.*.*.*) ADDR=$1; PORT=${2:-8443};;
  *) PORT=${1:-443};;
esac
SRC=/etc/openvpn/server/lattice-cnsa2.conf
C=/etc/openvpn/server/lattice-cnsa2-tcp.conf
UNIT=openvpn-server@lattice-cnsa2-tcp
DD=/etc/systemd/system/$UNIT.service.d
WAN=$(ip route show default | awk '{print $5; exit}')

case "$PORT" in ''|*[!0-9]*) echo "port must be a number"; exit 1;; esac
[ -f "$SRC" ] || { echo "no CNSA 2.0 gateway on this server; nothing changed"; exit 1; }
[ -n "$WAN" ] || { echo "cannot find the internet-facing interface; nothing changed"; exit 1; }
if [ -n "$ADDR" ]; then
  case "$ADDR" in *[!0-9.]*) echo "the second address must be an IPv4 address"; exit 1;; esac
  FIRST=$(ip -4 route get 1.1.1.1 | sed -n 's/.* src \([0-9.]*\).*/\1/p')
  [ "$ADDR" != "$FIRST" ] || { echo "$ADDR is this server's first address, where Caddy answers; give the second one. Nothing changed"; exit 1; }
  [ "$PORT" != 443 ] || { echo "with a second address the tunnel cannot listen on 443 itself; nothing changed"; exit 1; }
fi
# Has this exact set-up been done already?
SAME=no
if [ "$(systemctl is-active "$UNIT" 2>/dev/null || true)" = active ] && grep -q "^port $PORT\$" "$C" 2>/dev/null; then
  if [ -z "$ADDR" ] && ! grep -q 'REDIRECT' "$DD/lattice-nat.conf" 2>/dev/null; then SAME=yes; fi
  if [ -n "$ADDR" ] && grep -q -- "-d $ADDR -p tcp --dport 443 -j REDIRECT --to-ports $PORT" "$DD/lattice-nat.conf" 2>/dev/null; then SAME=yes; fi
fi

if [ "$SAME" = yes ]; then
  echo "already listening"
else
  if [ "$(systemctl is-active "$UNIT" 2>/dev/null || true)" != active ] && [ -n "$(ss -ltnH "sport = :$PORT")" ]; then
    echo "TCP $PORT is already in use on this server; nothing changed:"
    ss -ltnpH "sport = :$PORT" | sed 's/^/  /'
    exit 3
  fi

  # The TCP configuration is the UDP one with the transport, interface and address blocks changed.
  T=$(mktemp); trap 'rm -f "$T"' EXIT
  sed -e "s/^port .*/port $PORT/" \
      -e 's/^proto udp$/proto tcp-server/' \
      -e 's/^dev tun-cnsa2$/dev tun-cnsa2t/' \
      -e 's/^server 10\.88\.0\.0 255\.255\.224\.0$/server 10.88.32.0 255.255.224.0/' \
      -e 's#^server-ipv6 fd42:88::/64$#server-ipv6 fd42:89::/64#' \
      -e 's/^max-clients .*/max-clients 1000/' \
      -e '/^explicit-exit-notify/d' \
      -e '/^# Tell connected apps the gateway is restarting/d' \
      -e '1s/.*/# Lattice VPN CNSA 2.0 gateway, TCP listener for networks that block UDP. Made from lattice-cnsa2.conf by add-tcp443.sh./' \
      "$SRC" > "$T"
  printf '\n# Send each packet as soon as it is ready.\ntcp-nodelay\n' >> "$T"
  # Every line that had to change must have changed, and nothing may still point at the UDP gateway.
  for want in "^port $PORT\$" '^proto tcp-server$' '^dev tun-cnsa2t$' '^server 10\.88\.32\.0 255\.255\.224\.0$' '^tls-version-min 1\.3$' '^tls-groups MLKEM1024$' '^tls-verify ' '^max-clients 1000$'; do
    grep -q "$want" "$T" || { echo "the UDP configuration is not what this script expects (missing: $want); nothing changed"; exit 1; }
  done
  if grep -qE '^(proto udp|dev tun-cnsa2$|server 10\.88\.0\.0 |server-ipv6 fd42:88::|explicit-exit-notify)' "$T"; then
    echo "the TCP configuration would clash with the UDP gateway; nothing changed"; exit 1
  fi
  V6=no; grep -q '^server-ipv6 fd42:89::/64$' "$T" && V6=yes

  B=/var/backups/lattice-cnsa2-tcp-$(date -u +%Y%m%d); mkdir -p "$B"; chmod 700 "$B"
  [ -f "$B/iptables.rules" ] || { iptables-save > "$B/iptables.rules"; ufw status numbered > "$B/ufw-status.txt"; }
  [ ! -f "$C" ] || cp -p "$C" "$B/lattice-cnsa2-tcp.conf.before"
  install -m 600 "$T" "$C"

  # With a second address: make sure the interface has it, and send its port 443 to the tunnel.
  EXTRA="# no second address"
  if [ -n "$ADDR" ]; then
    EXTRA="ExecStartPre=/bin/sh -c 'ip -4 -o addr show | grep -q \" $ADDR/\" || ip addr add $ADDR/32 dev $WAN'
ExecStartPre=/bin/sh -c 'iptables -t nat -C PREROUTING -d $ADDR -p tcp --dport 443 -j REDIRECT --to-ports $PORT 2>/dev/null || iptables -t nat -A PREROUTING -d $ADDR -p tcp --dport 443 -j REDIRECT --to-ports $PORT'
ExecStopPost=-/bin/sh -c 'iptables -t nat -D PREROUTING -d $ADDR -p tcp --dport 443 -j REDIRECT --to-ports $PORT'"
  fi

  install -d "$DD"
  cat > "$DD/lattice-nat.conf" <<UNIT
# Restart with the UDP gateway, so a renewed certificate is picked up by both.
[Unit]
PartOf=openvpn-server@lattice-cnsa2.service
[Service]
ExecStartPre=/bin/sh -c 'iptables -t nat -C POSTROUTING -s 10.88.32.0/19 -o $WAN -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s 10.88.32.0/19 -o $WAN -j MASQUERADE'
ExecStartPre=/bin/sh -c 'iptables -t mangle -C FORWARD -i tun-cnsa2t -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -t mangle -A FORWARD -i tun-cnsa2t -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu'
ExecStartPre=/bin/sh -c 'iptables -t mangle -C FORWARD -o tun-cnsa2t -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -t mangle -A FORWARD -o tun-cnsa2t -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu'
ExecStopPost=-/bin/sh -c 'iptables -t nat -D POSTROUTING -s 10.88.32.0/19 -o $WAN -j MASQUERADE'
ExecStopPost=-/bin/sh -c 'iptables -t mangle -D FORWARD -i tun-cnsa2t -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu'
ExecStopPost=-/bin/sh -c 'iptables -t mangle -D FORWARD -o tun-cnsa2t -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu'
$EXTRA
UNIT
  if [ "$V6" = yes ]; then
    cat > "$DD/lattice-nat6.conf" <<UNIT
[Service]
ExecStartPre=/bin/sh -c 'ip6tables -t nat -C POSTROUTING -s fd42:89::/64 -o $WAN -j MASQUERADE 2>/dev/null || ip6tables -t nat -A POSTROUTING -s fd42:89::/64 -o $WAN -j MASQUERADE'
ExecStartPre=/bin/sh -c 'ip6tables -t mangle -C FORWARD -i tun-cnsa2t -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || ip6tables -t mangle -A FORWARD -i tun-cnsa2t -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu'
ExecStartPre=/bin/sh -c 'ip6tables -t mangle -C FORWARD -o tun-cnsa2t -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || ip6tables -t mangle -A FORWARD -o tun-cnsa2t -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu'
ExecStopPost=-/bin/sh -c 'ip6tables -t nat -D POSTROUTING -s fd42:89::/64 -o $WAN -j MASQUERADE'
ExecStopPost=-/bin/sh -c 'ip6tables -t mangle -D FORWARD -i tun-cnsa2t -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu'
ExecStopPost=-/bin/sh -c 'ip6tables -t mangle -D FORWARD -o tun-cnsa2t -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu'
UNIT
  else
    rm -f "$DD/lattice-nat6.conf"
  fi

  ufw allow "$PORT/tcp" comment 'Lattice CNSA 2.0 over TCP' >/dev/null
  ufw route allow in on tun-cnsa2t out on "$WAN" >/dev/null
  systemctl daemon-reload
  systemctl enable -q "$UNIT"
  systemctl restart "$UNIT"
  sleep 4
  if [ "$(systemctl is-active "$UNIT")" != active ]; then
    echo "the TCP listener did not start; taking it out again. Its last messages:"
    journalctl -u "$UNIT" --no-pager -n 8 | sed 's/^.*openvpn\[[0-9]*\]: /  /' | cut -c1-160
    systemctl disable -q --now "$UNIT" || true
    ufw delete allow "$PORT/tcp" >/dev/null || true
    ufw route delete allow in on tun-cnsa2t out on "$WAN" >/dev/null || true
    exit 1
  fi
fi

echo "tcp listener: $(systemctl is-active "$UNIT") | listening tcp $PORT: $(ss -ltnH "sport = :$PORT" | wc -l) | tunnel: $(ip -4 -o addr show tun-cnsa2t 2>/dev/null | awk '{print $4}')"
if [ -n "$ADDR" ]; then
  echo "second address: $ADDR on $WAN: $(ip -4 -o addr show | grep -c " $ADDR/") | 443 sent to $PORT: $(iptables -t nat -S PREROUTING | grep -c -- "-d $ADDR/32 -p tcp -m tcp --dport 443 -j REDIRECT --to-ports $PORT") | caddy still on 443: $(ss -ltnpH 'sport = :443' | grep -c caddy)"
fi
echo "nat for 10.88.32.0/19: $(iptables -t nat -S POSTROUTING | grep -c '10.88.32.0/19') | ufw: $(ufw status | grep -c "^$PORT/tcp ")"
echo "untouched: udp gateway $(systemctl is-active openvpn-server@lattice-cnsa2), udp 1194 listening $(ss -lunH | grep -c ':1194 '), wireguard $(wg show wg0 2>/dev/null | grep -c 'listening port')"
echo "memory: $(free -m | awk '/^Mem:/ {print $7 " MB available of " $2}')"
