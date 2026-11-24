#!/bin/bash
# Upgrades one Lattice VPN server from Ubuntu 24.04 to 26.04 LTS in place and
# checks it afterwards. Run from the operator's machine; needs root SSH.
#
#   upgrade-one.sh <name> <ip> <public health host or -> <helper ip for the live tunnel test or ->
#
# Take a provider snapshot first. The script stops with a non-zero exit at the
# first thing that does not look right and leaves the server as it is.
# Exit: 0 upgraded and healthy, 1 failed a check, 2 the upgrade stalled.
set -u
N=$1; IP=$2; HOST=$3; HELPER=${4:--}
HERE="$(cd "$(dirname "$0")" && pwd)"
SSH="ssh ${LATTICE_SSH_OPTS:-} -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=10 root@$IP"
KIND=${LATTICE_KIND:-vpn}   # vpn: a concentrator. monitor: the Docker monitoring server.
RESUME=${LATTICE_RESUME:-}   # step1 or step2: that step is already running on the server (the local run was interrupted); pick it up there.
S() { $SSH "$@" 2>&1 | grep -v "Pseudo-terminal"; return "${PIPESTATUS[0]}"; }
log() { echo "$(date +%T) [$N] $*"; }
die() { log "STOPPED: $*"; exit "${2:-1}"; }
waitssh() { for _ in $(seq 1 45); do $SSH true 2>/dev/null && return 0; sleep 8; done; return 1; }
STOCK='^(systemd|dbus|cron|ssh|rsyslog|getty|serial-getty|polkit|unattended|multipathd|networkd|user@|snapd|ModemManager|udisks|fwupd|irqbalance|chrony|qemu|cloud|packagekit|upower|apt-|motd|e2scrub|fstrim|plymouth|thermald|hc-net|sysstat|emergency|rescue)'

health_monitor() {
  # Docker host: every container that ran before must be running, and the main endpoints must answer.
  local out bad=0
  for _ in $(seq 1 15); do
    out=$(S 'B=$(ls -d /var/backups/lattice-pre-2604-* | head -1)
      . /etc/os-release; echo "os: $PRETTY_NAME | kernel $(uname -r) | openssl $(openssl version | cut -d" " -f2) | up $(uptime -p)"
      missing=""; for s in $(grep -v -E "'"$STOCK"'" $B/running-services.txt); do [ "$(systemctl is-active $s 2>/dev/null)" = active ] || missing="$missing $s"; done
      echo "services down that were up before:${missing:- none}"
      echo "failed units: $(systemctl --failed --no-legend | awk "{print \$2}" | tr "\n" " ")"
      gone=""; for c in $(cat $B/containers.txt); do [ "$(docker inspect -f "{{.State.Running}}" $c 2>/dev/null)" = true ] || gone="$gone $c"; done
      echo "containers not running that ran before:${gone:- none} ($(docker ps -q | wc -l) running)"
      ep=""; for u in 9090/-/ready 3000/api/health 3100/ready 9093/-/ready; do ep="$ep ${u%%/*}=$(curl -s -o /dev/null -w %{http_code} --max-time 5 http://127.0.0.1:$u)"; done
      echo "endpoints:$ep"')
    bad=0
    echo "$out" | grep -q "services down that were up before: none" || bad=1
    echo "$out" | grep -q "^failed units: $" || bad=1
    echo "$out" | grep -q "containers not running that ran before: none" || bad=1
    echo "$out" | grep -q "endpoints: 9090=200 3000=200 3100=200 9093=200" || bad=1
    [ $bad = 0 ] && break; sleep 12
  done
  echo "$out" | sed "s/^/           /"
  return $bad
}

health() {
  if [ "$KIND" = monitor ]; then health_monitor; return $?; fi
  # prints a summary; returns 0 only if everything that ran before still runs
  local out bad=0
  out=$(S 'B=$(ls -d /var/backups/lattice-pre-2604-* | head -1)
    . /etc/os-release; echo "os: $PRETTY_NAME | kernel $(uname -r) | openssl $(openssl version | cut -d" " -f2) | up $(uptime -p)"
    missing=""; for s in $(grep -v -E "'"$STOCK"'" $B/running-services.txt); do [ "$(systemctl is-active $s 2>/dev/null)" = active ] || missing="$missing $s"; done
    echo "services down that were up before:${missing:- none}"
    echo "failed units: $(systemctl --failed --no-legend | awk "{print \$2}" | tr "\n" " ")"
    echo "wg: peers $(wg show wg0 2>/dev/null | grep -c "^peer") (before $(cat $B/wg-peers.txt)) | forward $(sysctl -n net.ipv4.ip_forward) | nat rules $(iptables -t nat -S POSTROUTING 2>/dev/null | grep -c MASQUERADE) | $(ufw status | head -1)"
    echo "local healthz: $(curl -s -o /dev/null -w %{http_code} --max-time 5 http://127.0.0.1:8090/healthz)"')
  echo "$out" | sed "s/^/           /"
  echo "$out" | grep -q "services down that were up before: none" || bad=1
  echo "$out" | grep -q "^failed units: $" || bad=1
  echo "$out" | grep -q "local healthz: 200" || bad=1
  echo "$out" | grep -q "forward 1 | nat rules [1-9]" || bad=1
  echo "$out" | grep -q "Status: active" || bad=1
  if [ "$HOST" != - ]; then
    local code; code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$HOST/healthz")
    echo "           public healthz: $code"; [ "$code" = 200 ] || bad=1
  fi
  return $bad
}

log "start"
waitssh || die "cannot reach the server"
if [ -z "$RESUME" ]; then
S '. /etc/os-release; echo $VERSION_ID' | grep -q '^24.04' || die "not on Ubuntu 24.04 (already upgraded?)"
# Ubuntu's release-information server answers 503 now and then (seen Nov 23), so ask more than once.
offered() { for _ in $(seq 1 15); do S 'do-release-upgrade -c 2>&1 | grep -c "26.04"' | grep -q '^[1-9]' && return 0; sleep 20; done; return 1; }
offered || die "26.04 is not offered to this server"

log "memory: $(S 'free -m | grep Mem: | tr -s " " | cut -d" " -f2') MB total"
log "saving configuration on the server"
S 'set -e; B=/var/backups/lattice-pre-2604-$(date -u +%Y%m%d); mkdir -p $B; chmod 700 $B
  [ -f $B/running-services.txt ] && exit 0
  tar -C / -czf $B/etc.tgz etc/wireguard etc/ufw etc/caddy etc/systemd/system etc/apt etc/cloakvpn etc/sysctl.conf etc/sysctl.d 2>/dev/null || true
  iptables-save > $B/iptables.rules; ip6tables-save > $B/ip6tables.rules; nft list ruleset > $B/nft.ruleset 2>/dev/null || true
  dpkg --get-selections > $B/packages.txt
  systemctl list-units --type=service --state=running --no-legend | awk "{print \$1}" > $B/running-services.txt
  wg show wg0 2>/dev/null | grep -c "^peer" > $B/wg-peers.txt || true
  if command -v docker >/dev/null; then docker ps --format "{{.Names}}" > $B/containers.txt; tar -C / -czf $B/docker-config.tgz etc/docker opt/lattice-monitoring 2>/dev/null || true; fi' || die "backup failed"

log "baseline"
health || die "not healthy before starting; refusing to upgrade"
fi

if [ "$RESUME" = step2 ]; then :
elif [ "$RESUME" != step1 ] && S 'apt-get update >/dev/null 2>&1; [ "$(apt list --upgradable 2>/dev/null | grep -c /)" = 0 ] && [ ! -f /var/run/reboot-required ]'; then
  log "step 1: nothing pending on 24.04, skipping the first reboot"
else
  log "step 1: pending updates on 24.04"
  [ "$RESUME" = step1 ] || S 'tmux kill-session -t upg 2>/dev/null; rm -f /var/log/lattice-upg-step1.log
    tmux new-session -d -s upg "export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a; (apt-get update && apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold dist-upgrade && apt-get -y autoremove; echo STEP1_RC=\$?) > /var/log/lattice-upg-step1.log 2>&1"'
  for _ in $(seq 1 80); do sleep 15; r=$(S 'grep -a -o "STEP1_RC=[0-9]*" /var/log/lattice-upg-step1.log'); [ -n "$r" ] && break; done
  [ "${r:-}" = "STEP1_RC=0" ] || die "pending updates did not finish cleanly (${r:-no result})"

  log "reboot on 24.04"
  S '(sleep 2; systemctl reboot) >/dev/null 2>&1 &'; sleep 45
  waitssh || die "did not come back after the first reboot"
  sleep 25
  health || die "not healthy after updates and reboot; 26.04 upgrade not started"

fi

# Right after a boot the release check can briefly say nothing is available.
[ "$RESUME" = step2 ] || for _ in $(seq 1 12); do S 'do-release-upgrade -c 2>&1 | grep -c "26.04"' | grep -q '^[1-9]' && break; sleep 20; done
[ "$RESUME" = step2 ] || S 'do-release-upgrade -c 2>&1 | grep -c "26.04"' | grep -q '^[1-9]' || die "26.04 is not offered to this server"

log "step 2: release upgrade to 26.04"
run_step2() {
[ "$RESUME" = step2 ] || S 'cat > /root/lattice-conffile-watch.sh <<"W"
#!/bin/bash
# Answers "keep the current file" when dpkg asks about a changed configuration
# file and the release upgrader has not answered it itself.
L=/var/log/lattice-upg-step2.log
prompt() { tail -c 200 $L 2>/dev/null | tr "\r" "\n" | grep -a -v "^$" | tail -1 | grep -aqE "\(Y/I/N/O/D/Z\) \[default=N\] \? ?$"; }
while ! grep -aq "STEP2_RC=" $L 2>/dev/null; do
  sleep 20
  prompt || continue
  size=$(stat -c %s $L); sleep 20
  prompt && [ "$size" = "$(stat -c %s $L)" ] || continue
  for p in $(pgrep -x dpkg); do
    t=$(readlink /proc/$p/fd/0)
    case "$t" in /dev/pts/*)
      python3 -c "import fcntl,termios,os,sys; fd=os.open(sys.argv[1],os.O_RDWR); [fcntl.ioctl(fd,termios.TIOCSTI,bytes([c])) for c in b\"N\n\"]" "$t" \
        && echo "$(date -u +%FT%TZ) kept current file: $(tail -c 600 $L | tr "\r" "\n" | grep -a "^Configuration file" | tail -1)" >> /var/log/lattice-conffile-watch.log
      sleep 30;;
    esac
  done
done
W
  chmod 700 /root/lattice-conffile-watch.sh; rm -f /var/log/lattice-upg-step2.log /var/log/lattice-conffile-watch.log
  tmux kill-session -t upg 2>/dev/null; tmux kill-session -t watch 2>/dev/null
  tmux new-session -d -s upg "export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a; (do-release-upgrade -f DistUpgradeViewNonInteractive; echo STEP2_RC=\$?) > /var/log/lattice-upg-step2.log 2>&1"
  tmux new-session -d -s watch /root/lattice-conffile-watch.sh'
last=0; same=0; r=""
for _ in $(seq 1 240); do
  sleep 20
  r=$(S 'grep -a -o "STEP2_RC=[0-9]*" /var/log/lattice-upg-step2.log | head -1'); [ -n "$r" ] && case "$r" in STEP2_RC=*) break;; esac
  lines=$($SSH 'grep -a -c "" /var/log/lattice-upg-step2.log' 2>/dev/null) || continue   # remote login restarts mid-upgrade
  case "$lines" in ''|*[!0-9]*) continue;; esac
  if [ "$lines" = "$last" ]; then same=$((same+1)); else same=0; last=$lines; fi
  [ $same -ge 24 ] && die "the upgrade has produced no output for 8 minutes: $(S 'tail -c 300 /var/log/lattice-upg-step2.log | tr "\r" "\n" | grep -a -v "^$" | tail -1' | cut -c1-140)" 2
done
}
attempt=1
while :; do
  run_step2
  [ "$r" = "STEP2_RC=0" ] && break
  if [ $attempt -lt 5 ] && S 'grep -aq "no development version of an LTS" /var/log/lattice-upg-step2.log'; then
    # Seen on us-central-1 and es1: shortly after a reboot the release tool can claim nothing is available.
    log "the release tool reported no release available (happens shortly after a reboot); retrying in 60 s"
    attempt=$((attempt+1)); RESUME=""; sleep 60; continue
  fi
  die "release upgrade did not finish cleanly (${r:-timed out})"
done
S '. /etc/os-release; echo $VERSION_ID' | grep -q '^26.04' || die "server does not report 26.04 after the upgrade"
kept=$(S 'cat /var/log/lattice-conffile-watch.log 2>/dev/null | wc -l'); log "release upgrade finished (configuration questions answered by the watcher: $kept)"

# 26.04 reserves 320 MB of a 2 GB server for crash dumps. With that taken, the new
# kernel can run out of memory during boot (seen on in1, Nov 23). Give it back first.
log "removing the crash-dump memory reservation before the first 26.04 boot"
$SSH 'bash -s' < "$HERE/no-crashkernel.sh" 2>&1 | grep -v "Pseudo-terminal" | sed "s/^/           /"
S 'grep -c crashkernel /boot/grub/grub.cfg' | grep -q '^0$' || die "could not remove the crash-dump reservation; not rebooting into 26.04"

log "reboot into 26.04"
S '(sleep 2; systemctl reboot) >/dev/null 2>&1 &'; sleep 45
waitssh || die "did not come back after the 26.04 reboot"
sleep 30

log "post-upgrade fixes"
S 'B=$(ls -d /var/backups/lattice-pre-2604-* | head -1)
  f=/etc/apt/sources.list.d/caddy-stable.list
  if [ -f $f ] && ! grep -q "^deb " $f && tar -tzf $B/etc.tgz ${f#/} >/dev/null 2>&1; then
    tar -xzOf $B/etc.tgz ${f#/} > $f.restore && grep -q "^deb " $f.restore && mv $f.restore $f && echo "restored the Caddy software source"
  fi
  apt-get update >/dev/null 2>&1
  sleep 25
  for u in $(systemctl list-units --no-legend "serial-getty@*.service" | awk "{print \$1}"); do
    if journalctl -b --no-pager -u "$u" 2>/dev/null | grep -q "failed to get terminal attributes"; then systemctl mask --now "$u" >/dev/null 2>&1 && echo "switched off the failing login prompt $u"; fi
  done
  systemctl reset-failed 2>/dev/null; true' | sed "s/^/           /"

log "final checks"
health || die "upgraded to 26.04 but a check failed; needs attention"
if [ "$HELPER" != - ]; then
  t=$(sh "$HERE/wgtest.sh" "$IP" "$HELPER"); echo "$t" | sed "s/^/           /"
  echo "$t" | grep -q "handshake: yes" || die "live tunnel test: no handshake"
  echo "$t" | grep -q "exit address seen by the internet: ip=$IP" || die "live tunnel test: traffic did not leave through this server"
fi
log "DONE: upgraded and healthy"
