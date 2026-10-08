#!/bin/bash
# What receives netflow on the monitoring VM, and is anything persisted?
ssh -o BatchMode=yes -o ConnectTimeout=6 root@178.104.136.167 '
  echo "=== what listens on :6343 ===";
  ss -ulnp | grep 6343;
  echo; echo "=== process detail ===";
  ps aux | grep -iE "nfcapd|goflow|flow|akvorado|pmacct" | grep -v grep;
  echo; echo "=== flow data on disk? ===";
  find / -xdev \( -iname "*nfcapd*" -o -iname "*flow*" \) -type f -newer /etc/hostname -size +0 2>/dev/null | grep -vE "proc|sys|overflow|pflowd" | head -15;
  echo; echo "=== du of common collector dirs ===";
  du -sh /var/lib/nfdump /var/cache/nfdump /var/flow* /opt/*flow* 2>/dev/null;
' 2>&1
