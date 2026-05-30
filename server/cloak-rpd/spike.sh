#!/usr/bin/env bash
# Local two-endpoint NO-DISRUPTION spike for cloak-rpd. Fully isolated from the
# box's production rosenpass: separate UDP port (19999), separate psk dir, own
# control socket. Proves: a runtime ADD of peer B (over the control socket)
# completes a handshake WITHOUT restarting the daemon and WITHOUT disturbing
# peer A's already-established session.
#
# PASS criteria (printed at the end):
#   psk-peer-A present            -> A handshake works
#   psk-peer-B present            -> runtime ADD works (the whole point)
#   rpd_pid unchanged             -> no daemon restart (zero disruption)
#   A_psk_present_after_B = yes   -> A's session not torn down by B's add
set -uo pipefail
RP=/root/rp/target/release/rosenpass
RPD=/root/rp/target/release/cloak-rpd
D=/root/cloak-build/spike
rm -rf "$D"; mkdir -p "$D/peers" "$D/psk"

echo "[spike] gen keypairs"
"$RP" gen-keys --secret-key "$D/server.sk" --public-key "$D/server.pk" >/dev/null 2>&1
"$RP" gen-keys --secret-key "$D/A.sk" --public-key "$D/A.pk" >/dev/null 2>&1
"$RP" gen-keys --secret-key "$D/B.sk" --public-key "$D/B.pk" >/dev/null 2>&1

# Pre-load peer A; stage B's pubkey for a RUNTIME add (not in peers dir).
cp "$D/A.pk" "$D/peers/peer-A.rosenpass-public"
cp "$D/B.pk" "$D/peer-B.rosenpass-public"

echo "[spike] start cloak-rpd (responder) on 127.0.0.1:19999"
nice -n 19 "$RPD" --secret-key "$D/server.sk" --public-key "$D/server.pk" \
  --listen 127.0.0.1:19999 --control "$D/control.sock" \
  --peers-dir "$D/peers" --psk-dir "$D/psk" >"$D/rpd.log" 2>&1 &
RPD_PID=$!
sleep 2

echo "[spike] start client A (initiator, V03)"
cat > "$D/A.toml" <<EOF
public_key = "$D/A.pk"
secret_key = "$D/A.sk"
listen = ["127.0.0.1:20001"]

[[peers]]
public_key = "$D/server.pk"
endpoint = "127.0.0.1:19999"
key_out = "$D/A.psk"
protocol_version = "V03"
EOF
nice -n 19 "$RP" exchange-config "$D/A.toml" >"$D/A.log" 2>&1 &
A_PID=$!

for i in $(seq 1 40); do [ -f "$D/psk/psk-peer-A" ] && break; sleep 1; done
A1=$([ -f "$D/psk/psk-peer-A" ] && echo yes || echo NO)

echo "[spike] ADD peer-B over control socket (runtime, no restart)"
python3 - "$D/control.sock" "peer-B" "$D/peer-B.rosenpass-public" <<'PY'
import socket,sys
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.connect(sys.argv[1])
s.sendall(("ADD %s %s\n"%(sys.argv[2],sys.argv[3])).encode()); s.close()
PY

echo "[spike] start client B (initiator, V03)"
cat > "$D/B.toml" <<EOF
public_key = "$D/B.pk"
secret_key = "$D/B.sk"
listen = ["127.0.0.1:20002"]

[[peers]]
public_key = "$D/server.pk"
endpoint = "127.0.0.1:19999"
key_out = "$D/B.psk"
protocol_version = "V03"
EOF
nice -n 19 "$RP" exchange-config "$D/B.toml" >"$D/B.log" 2>&1 &
B_PID=$!

for i in $(seq 1 40); do [ -f "$D/psk/psk-peer-B" ] && break; sleep 1; done
B1=$([ -f "$D/psk/psk-peer-B" ] && echo yes || echo NO)

sleep 3
A2=$([ -f "$D/psk/psk-peer-A" ] && echo yes || echo NO)
RPD_ALIVE=$(kill -0 "$RPD_PID" 2>/dev/null && echo yes || echo NO)
RPD_NOW=$(pgrep -f "target/release/cloak-rpd" | head -1)

kill "$A_PID" "$B_PID" "$RPD_PID" 2>/dev/null

echo "================ SPIKE RESULT ================"
echo "psk-peer-A present (A handshake)      : $A1"
echo "psk-peer-B present (runtime ADD works): $B1"
echo "A psk present after B add (no tear)   : $A2"
echo "rpd start pid=$RPD_PID alive=$RPD_ALIVE current_pid=$RPD_NOW (same => no restart)"
echo "--- rpd.log (last 8) ---"; tail -8 "$D/rpd.log"
if [ "$A1" = yes ] && [ "$B1" = yes ] && [ "$A2" = yes ] && [ "$RPD_ALIVE" = yes ]; then
  echo "SPIKE_PASS"
else
  echo "SPIKE_FAIL"
fi
