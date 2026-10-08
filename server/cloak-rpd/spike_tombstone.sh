#!/usr/bin/env bash
# Tombstone/re-ADD regression spike for cloak-rpd (the 2026-07-01 bug).
# Fully isolated: separate UDP port (19998), own psk dir + control socket.
#
# Scenario (exactly what a device revoke + re-provision does):
#   1. runtime-ADD peer B, handshake      -> psk-peer-B written
#   2. REMOVE peer B                      -> psk-peer-B deleted, slot tombstoned
#   3. re-ADD peer B (same name+key)      -> must REACTIVATE the slot
#   4. fresh handshake from B             -> psk-peer-B must be REWRITTEN
#      (the old binary completed the handshake but silently wrote NOTHING)
#   5. duplicate ADD while active         -> idempotent no-op, B still works
#   6. peer A (preloaded) untouched throughout, daemon never restarts.
#
# PASS criteria printed at the end; exits 0 only on TOMBSTONE_SPIKE_PASS.
set -uo pipefail
RP=${RP:-/root/cloak-rpd-build/rp/target/release/rosenpass}
RPD=${RPD:-/root/cloak-rpd-build/rp/target/release/cloak-rpd}
D=/root/cloak-rpd-build/spike-tombstone
rm -rf "$D"; mkdir -p "$D/peers" "$D/psk"

ctl() { python3 - "$D/control.sock" "$@" <<'PY'
import socket,sys
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.connect(sys.argv[1])
s.sendall((" ".join(sys.argv[2:])+"\n").encode()); s.close()
PY
}

client_b_once() { # one fresh exchange run for B; waits for psk-peer-B
  cat > "$D/B.toml" <<EOF
public_key = "$D/B.pk"
secret_key = "$D/B.sk"
listen = ["127.0.0.1:$1"]

[[peers]]
public_key = "$D/server.pk"
endpoint = "127.0.0.1:19998"
key_out = "$D/B.psk"
protocol_version = "V03"
EOF
  nice -n 19 "$RP" exchange-config "$D/B.toml" >>"$D/B.log" 2>&1 &
  B_PID=$!
  for i in $(seq 1 40); do [ -f "$D/psk/psk-peer-B" ] && break; sleep 1; done
  local present=$([ -f "$D/psk/psk-peer-B" ] && echo yes || echo NO)
  kill "$B_PID" 2>/dev/null; wait "$B_PID" 2>/dev/null
  echo "$present"
}

echo "[spike-t] gen keypairs"
"$RP" gen-keys --secret-key "$D/server.sk" --public-key "$D/server.pk" >/dev/null 2>&1
"$RP" gen-keys --secret-key "$D/A.sk" --public-key "$D/A.pk" >/dev/null 2>&1
"$RP" gen-keys --secret-key "$D/B.sk" --public-key "$D/B.pk" >/dev/null 2>&1
cp "$D/A.pk" "$D/peers/peer-A.rosenpass-public"
cp "$D/B.pk" "$D/peer-B.rosenpass-public"

echo "[spike-t] start cloak-rpd on 127.0.0.1:19998"
nice -n 19 "$RPD" --secret-key "$D/server.sk" --public-key "$D/server.pk" \
  --listen 127.0.0.1:19998 --control "$D/control.sock" \
  --peers-dir "$D/peers" --psk-dir "$D/psk" >"$D/rpd.log" 2>&1 &
RPD_PID=$!
sleep 2

echo "[spike-t] client A up (preloaded peer, stays up the whole test)"
cat > "$D/A.toml" <<EOF
public_key = "$D/A.pk"
secret_key = "$D/A.sk"
listen = ["127.0.0.1:20011"]

[[peers]]
public_key = "$D/server.pk"
endpoint = "127.0.0.1:19998"
key_out = "$D/A.psk"
protocol_version = "V03"
EOF
nice -n 19 "$RP" exchange-config "$D/A.toml" >"$D/A.log" 2>&1 &
A_PID=$!
for i in $(seq 1 40); do [ -f "$D/psk/psk-peer-A" ] && break; sleep 1; done
A1=$([ -f "$D/psk/psk-peer-A" ] && echo yes || echo NO)

echo "[spike-t] 1) runtime ADD peer-B + first handshake"
ctl ADD peer-B "$D/peer-B.rosenpass-public"
sleep 1
B1=$(client_b_once 20012)

echo "[spike-t] 2) REMOVE peer-B (tombstone)"
ctl REMOVE peer-B
sleep 1
B_GONE=$([ ! -f "$D/psk/psk-peer-B" ] && echo yes || echo NO)

echo "[spike-t] 3+4) re-ADD peer-B, fresh handshake must REWRITE the psk"
ctl ADD peer-B "$D/peer-B.rosenpass-public"
sleep 1
B2=$(client_b_once 20013)

echo "[spike-t] 5) duplicate ADD while active — must stay working"
ctl ADD peer-B "$D/peer-B.rosenpass-public"
sleep 1
rm -f "$D/psk/psk-peer-B"
B3=$(client_b_once 20014)

A2=$([ -f "$D/psk/psk-peer-A" ] && echo yes || echo NO)
RPD_ALIVE=$(kill -0 "$RPD_PID" 2>/dev/null && echo yes || echo NO)

kill "$A_PID" "$RPD_PID" 2>/dev/null

echo "================ TOMBSTONE SPIKE RESULT ================"
echo "A first handshake (preload)            : $A1"
echo "B first handshake (runtime ADD)        : $B1"
echo "B psk deleted on REMOVE                : $B_GONE"
echo "B psk REWRITTEN after re-ADD (THE BUG) : $B2"
echo "B works after duplicate ADD            : $B3"
echo "A psk still present at end             : $A2"
echo "daemon never restarted                 : $RPD_ALIVE"
echo "--- rpd.log (tail) ---"; tail -6 "$D/rpd.log"
if [ "$A1" = yes ] && [ "$B1" = yes ] && [ "$B_GONE" = yes ] && \
   [ "$B2" = yes ] && [ "$B3" = yes ] && [ "$A2" = yes ] && [ "$RPD_ALIVE" = yes ]; then
  echo "TOMBSTONE_SPIKE_PASS"; exit 0
else
  echo "TOMBSTONE_SPIKE_FAIL"; exit 1
fi
