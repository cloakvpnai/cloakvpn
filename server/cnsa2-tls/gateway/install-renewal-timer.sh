#!/bin/bash
# Run on a gateway as root, after cnsa2-gateway-renew.sh is in /etc/openvpn/server/lattice-cnsa2.
# Adds a daily check that renews the gateway's certificate in its last 30 days.
# Each gateway checks at a random time within six hours, so they do not all restart together.
set -eu
D=/etc/openvpn/server/lattice-cnsa2
chmod 755 "$D/cnsa2-gateway-renew.sh"
cat > /etc/systemd/system/lattice-cnsa2-gateway-renew.service <<UNIT
[Unit]
Description=Lattice CNSA 2.0 gateway certificate renewal
[Service]
Type=oneshot
EnvironmentFile=/etc/cloakvpn/regionsvc.env
ExecStart=/bin/sh -c 'umask 077; printf %%s "\$REGION_INTERNAL_SECRET" > /run/lattice-cnsa2-renew-secret; $D/cnsa2-gateway-renew.sh https://api.latticevpn.ai /run/lattice-cnsa2-renew-secret; rc=\$?; rm -f /run/lattice-cnsa2-renew-secret; exit \$rc'
UNIT
cat > /etc/systemd/system/lattice-cnsa2-gateway-renew.timer <<UNIT
[Unit]
Description=Lattice CNSA 2.0 gateway certificate renewal, daily
[Timer]
OnCalendar=daily
RandomizedDelaySec=6h
Persistent=true
[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable -q --now lattice-cnsa2-gateway-renew.timer
echo "renewal timer: $(systemctl is-active lattice-cnsa2-gateway-renew.timer), key hash $(openssl pkey -in $D/gateway.key -pubout -outform DER | sha384sum | cut -d' ' -f1)"
