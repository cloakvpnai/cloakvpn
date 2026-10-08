#!/bin/bash
# Deep-dive on us-west-1: peer ADD timeline + first exchange + regionsvc log.
ssh -o BatchMode=yes -o ConnectTimeout=6 root@5.78.203.171 '
  echo "=== cloak-rpd journal: peer-7bc7a25d3e97 first 15 lines mentioning it ===";
  journalctl -u cloak-rpd --no-pager | grep -i "7bc7a25d3e97" | head -15;
  echo;
  echo "=== cloak-rpd journal: ADD / add_peer / control lines (last 20) ===";
  journalctl -u cloak-rpd --no-pager | grep -iE "ADD|control|added" | tail -20;
  echo;
  echo "=== regionsvc / api journal around provisions (last 30) ===";
  journalctl -u cloakvpn-api --no-pager -n 200 | grep -iE "provision|device|ADD|rosenpass" | tail -30;
  echo;
  echo "=== exchange cadence: all output-key lines for the peer ===";
  journalctl -u cloak-rpd --no-pager | grep "7bc7a25d3e97" | grep -c "exchanged";
  journalctl -u cloak-rpd --no-pager | grep "7bc7a25d3e97" | grep -c "stale";
  echo "=== first and last 3 ===";
  journalctl -u cloak-rpd --no-pager | grep "7bc7a25d3e97" | head -3;
  journalctl -u cloak-rpd --no-pager | grep "7bc7a25d3e97" | tail -3;
' 2>&1
