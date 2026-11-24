#!/bin/sh
# Parallel-stream throughput through the test tunnel. Usage: lt-par.sh <gateway ip> <streams>
D=/root/cnsa2-loadtest
openvpn --config $D/client.conf --log $D/client.log --writepid $D/client.pid --daemon lt-throughput
sleep 6
ip link set tun-lt mtu 1380
B0=$(nstat -az UdpRcvbufErrors 2>/dev/null | awk '/UdpRcvbufErrors/{print $2}')
vmstat 1 12 > $D/vm.txt &
i=0
while [ $i -lt "$2" ]; do
  curl -s -o /dev/null -m 12 -w '%{speed_download}\n' http://10.89.0.1:8000/zero >> $D/par.txt &
  i=$((i+1))
done
wait
awk '{s+=$1} END {printf "streams %d total %.1f MB/s = %.0f Mbit/s\n", NR, s/1e6, s*8/1e6}' $D/par.txt
awk 'NR>3 {us+=$13; sy+=$14; id+=$15; st+=$17; n++} END {printf "client cpu avg: us %.0f sy %.0f idle %.0f steal %.0f\n", us/n, sy/n, id/n, st/n}' $D/vm.txt
B1=$(nstat -az UdpRcvbufErrors 2>/dev/null | awk '/UdpRcvbufErrors/{print $2}')
echo "client UDP receive buffer drops during run: $((B1-B0))"
rm -f $D/par.txt
kill "$(cat $D/client.pid)" || true
