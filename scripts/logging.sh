#!/bin/sh
# Real firewall logs: run ulogd on fw-site-a so nftables "log" events become syslog messages.
# Path: nftables (log group 1) -> NFLOG -> ulogd -> syslog -> rsyslog -> tunnel -> collector
# Usage: sh scripts/logging.sh   (scripts/rebuild.sh calls it after zones.sh)
# Safe to run again: it stops any running ulogd before starting a new one.
# ulogd itself is installed by rebuild.sh, before the firewall rules block the
# container's own internet access.
set -e
cd "$(dirname "$0")/.."

P=clab-bank-sec-lab
A=$P-fw-site-a
S=$P-rsyslog-server

echo "## 1. Start ulogd on fw-site-a"
docker cp configs/ulogd.conf "$A:/etc/ulogd.conf"
docker exec "$A" sh -c 'pkill ulogd 2>/dev/null; sleep 1; ulogd -d -c /etc/ulogd.conf'
sleep 1
if docker exec "$A" pgrep ulogd >/dev/null 2>&1; then
  echo "  ulogd is running"
else
  echo "  FAILED: ulogd is not running. Look at: docker exec $A cat /var/log/ulogd.log"
  exit 1
fi

echo "## 2. End-to-end test: a blocked packet should appear on the collector"
docker exec "$P-pc1" ping -c1 -W1 192.0.2.130 >/dev/null 2>&1 || true
sleep 2
if docker exec "$S" grep -q "FWA-DROP-FORWARD" /var/log/remote/fw-site-a/syslog.log 2>/dev/null; then
  echo "  OK: a firewall drop event arrived at the collector:"
  docker exec "$S" grep "FWA-DROP-FORWARD" /var/log/remote/fw-site-a/syslog.log | tail -n 1
else
  echo "  FAILED: no firewall event reached the collector. See 'If something fails' in the guide."
  exit 1
fi
