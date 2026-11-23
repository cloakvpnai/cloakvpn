#!/bin/sh
# Lab only: enrolls a phone or emulator with the TLS lab CA and points its
# CNSA 2.0 mode at the lab gateway. The device key is made on the device and
# never leaves it; only the certificate request comes across.
#   lab-enroll.sh <device name, e.g. a16.tls.lattice.lab> <gateway host> <rekey seconds> [adb options, e.g. -e or -s SERIAL]
set -eu
NAME="$1"; HOST="$2"; REKEY="$3"; shift 3
HERE="$(cd "$(dirname "$0")" && pwd)"; PKI="$HERE/../../../server/cnsa2-tls/lab/pki"
ADB="${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}"; PKG=ai.latticevpn.android; ACT=$PKG/.cnsa2.Cnsa2LabActivity
W="$HOME/src/cnsa2-enroll.$$"; mkdir -p "$W"; trap 'rm -rf "$W"' EXIT
"$ADB" "$@" shell am start -n $ACT --es enroll "$NAME" >/dev/null
sleep 4
"$ADB" "$@" exec-out run-as $PKG cat files/cnsa2/request.der > "$W/request.der"
printf 'basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth\nsubjectAltName=DNS:%s\n' "$NAME" > "$W/ext"
docker run --rm -v "$PKI:/pki:ro" -v "$W:/w" lattice-cnsa2-tls-lab sh -euc '
  openssl req -inform DER -in /w/request.der -verify -noout 2>&1 | head -1
  openssl x509 -req -inform DER -in /w/request.der -CA /pki/ca.pem -CAkey /pki/ca.key -CAcreateserial -CAserial /w/serial \
    -days 30 -extfile /w/ext -outform DER -out /w/client.der 2>/dev/null
  openssl x509 -inform DER -in /w/client.der -noout -subject -enddate'
"$ADB" "$@" shell am start -n $ACT --es certificate "$(base64 < "$W/client.der" | tr -d '\n')" >/dev/null
sleep 2
"$ADB" "$@" shell am start -n $ACT --es gateway "$(python3 "$HERE/lab-config.py" "$PKI/ca.pem" "$HOST" "$REKEY")" >/dev/null
sleep 2
echo "protection: $("$ADB" "$@" shell run-as $PKG cat files/cnsa2/protection.txt)"
