# usage: wgtest.sh <target ip> <helper ip>   Proves WireGuard handshake, forwarding and NAT on <target> using a throwaway peer from <helper>.
T=$1; H=$2; TIP=10.99.0.250
S() { ssh -o BatchMode=yes -o ConnectTimeout=10 root@$1 "$2" 2>&1 | grep -v Pseudo; }
TPUB=$(S $T 'wg show wg0 public-key'); TADDR=$(S $T "ip -4 -o addr show wg0 | awk '{print \$4}' | cut -d/ -f1")
[ "$(S $T "wg show wg0 allowed-ips | grep -c '$TIP/32'")" = 0 ] || { echo "test address in use on target"; exit 1; }
HPUB=$(S $H 'umask 077; ip netns del wgt 2>/dev/null; wg genkey > /etc/wireguard/.wgt-test.key; wg pubkey < /etc/wireguard/.wgt-test.key')
S $T "wg set wg0 peer $HPUB allowed-ips $TIP/32"
S $H "ip netns add wgt && ip link add wgt type wireguard && ip link set wgt netns wgt && ip netns exec wgt wg set wgt private-key /etc/wireguard/.wgt-test.key peer $TPUB endpoint $T:51820 allowed-ips 0.0.0.0/0 && ip netns exec wgt ip addr add $TIP/32 dev wgt && ip netns exec wgt ip link set wgt up && ip netns exec wgt ip route add default dev wgt
echo \"ping tunnel address $TADDR: \$(ip netns exec wgt ping -c 3 -W 2 $TADDR | grep -o '[0-9]* received')\"
echo \"ping 1.1.1.1 through tunnel: \$(ip netns exec wgt ping -c 3 -W 2 1.1.1.1 | grep -o '[0-9]* received')\"
echo \"exit address seen by the internet: \$(ip netns exec wgt curl -s --max-time 8 https://1.1.1.1/cdn-cgi/trace | grep '^ip=')\"
echo \"handshake: \$(ip netns exec wgt wg show wgt latest-handshakes | awk '{print (\$2>0)?\"yes\":\"no\"}')\"
ip netns del wgt; rm -f /etc/wireguard/.wgt-test.key"
S $T "wg set wg0 peer $HPUB remove; echo \"target peers after cleanup: \$(wg show wg0 | grep -c '^peer')\""
