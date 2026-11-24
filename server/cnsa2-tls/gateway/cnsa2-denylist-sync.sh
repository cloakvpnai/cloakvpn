#!/bin/sh
# Fetches the CNSA 2.0 deny list from the account API and installs it atomically.
#   cnsa2-denylist-sync.sh <api base url> <file holding the internal secret> <deny list path>
# Run every few minutes (systemd timer). Keeps the previous list if the fetch
# fails or the reply is cut off: the reply must end with "# end <count>" and the
# count must match.
set -eu
URL="$1"; SECRET_FILE="$2"; LIST="$3"
TMP="$LIST.new.$$"; trap 'rm -f "$TMP"' EXIT
umask 022
if ! curl -fsS --max-time 20 -H "Authorization: Bearer $(cat "$SECRET_FILE")" \
     "$URL/v1/internal/cnsa2/denylist" -o "$TMP"; then
  echo "deny list: fetch failed, keeping the current list" >&2; exit 1
fi
want=$(sed -n '$s/^# end \([0-9][0-9]*\)$/\1/p' "$TMP")
have=$(grep -c -v '^#' "$TMP" || true)
if [ -z "$want" ] || [ "$want" != "$have" ]; then
  echo "deny list: incomplete reply, keeping the current list" >&2; exit 1
fi
if grep -v '^#' "$TMP" | grep -q -v -E '^[0-9a-f]{1,40}$'; then
  echo "deny list: unexpected content, keeping the current list" >&2; exit 1
fi
mv -f "$TMP" "$LIST"
echo "deny list: $have serials"
