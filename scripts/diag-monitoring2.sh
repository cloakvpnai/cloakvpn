#!/bin/bash
# Where does monitoring report? What does the netflow exporter capture?
ssh -o BatchMode=yes -o ConnectTimeout=6 root@5.78.203.171 '
  echo "=== cloak-netflow unit ===";
  cat /etc/systemd/system/cloak-netflow.service 2>/dev/null;
  echo; echo "=== alloy remote endpoints ===";
  grep -rE "url|endpoint" /etc/alloy/ 2>/dev/null | head -10;
  echo; echo "=== node_exporter scraped by whom (recent) ===";
  journalctl -u node_exporter -n 3 --no-pager 2>/dev/null;
  echo; echo "=== prometheus scrape sources in firewall/hosts ===";
  grep -rE "monitor|grafana|prom" /etc/hosts 2>/dev/null;
' 2>&1
