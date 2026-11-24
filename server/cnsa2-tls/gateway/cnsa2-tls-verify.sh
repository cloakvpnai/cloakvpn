#!/bin/sh
# OpenVPN tls-verify hook for a CNSA 2.0 gateway.
#   tls-verify "/etc/lattice-cnsa2/cnsa2-tls-verify.sh /run/lattice-cnsa2/denylist"   (needs script-security 2)
# OpenVPN calls it as: <deny list> <depth> <subject>, with tls_serial_hex_0 in the environment.
# Refuses a device certificate whose serial is on the deny list. Chain, lifetime and
# usage checks have already been done by OpenSSL before this runs.
#
# If the deny list file does not exist at all the gateway refuses everyone: a
# gateway that was never given a list must not admit removed devices. A list that
# is merely old is still used; cnsa2-denylist-sync.sh keeps the last good copy when
# the account API cannot be reached, so an API outage does not disconnect customers.
LIST="$1"; DEPTH="$2"
[ "$DEPTH" = 0 ] || exit 0
[ -r "$LIST" ] || exit 1
serial=$(printf %s "${tls_serial_hex_0:-}" | tr -d ':' | tr 'A-F' 'a-f' | sed 's/^0*//')
[ -n "$serial" ] || exit 1
if grep -qxF "$serial" "$LIST"; then exit 1; fi
exit 0
