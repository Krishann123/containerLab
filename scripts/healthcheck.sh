#!/bin/sh
# Health check for the secure log pipeline: fw-site-a -> WireGuard tunnel -> collector.
# Usage: sh scripts/healthcheck.sh
# Exit code 0 = healthy, 1 = something is wrong.
# To monitor continuously:  while true; do sh scripts/healthcheck.sh; sleep 60; done
#
# Two kinds of checks:
#  - tunnel checks: is the link up, is the WireGuard session fresh, does the far end answer?
#  - canaries: a uniquely marked message is sent through the whole path and we look for it
#    at the collector. This is what proves logs really arrive. A tunnel can look "up" while
#    nothing flows, so the canaries matter most.
cd "$(dirname "$0")/.." || exit 1

P=clab-bank-sec-lab
A=$P-fw-site-a
S=$P-rsyslog-server
PC1=$P-pc1
LOGFILE=/var/log/remote/fw-site-a/syslog.log
MAX_HANDSHAKE_AGE=180   # WireGuard re-handshakes about every 2 minutes while traffic flows

TUNNEL_OK=1
SYSLOG_OK=1
EVENT_OK=1

if ! docker ps --format '{{.Names}}' | grep -q "^$A$"; then
  echo "The lab is not running. Start it with: sh scripts/rebuild.sh"
  exit 1
fi

echo "== Tunnel (fw-site-a to fw-site-b)"

if docker exec $A ip link show eth3 2>/dev/null | grep -q "state UP"; then
  echo "  OK    transit interface eth3 is up"
else
  echo "  FAIL  transit interface eth3 is not up"
  TUNNEL_OK=0
fi

HS=$(docker exec $A wg show wg0 latest-handshakes 2>/dev/null | awk 'NR==1 {print $2}')
NOW=$(date +%s)
if [ -z "$HS" ] || [ "$HS" = "0" ]; then
  echo "  FAIL  WireGuard has not completed a handshake"
  TUNNEL_OK=0
else
  AGE=$((NOW - HS))
  if [ "$AGE" -le "$MAX_HANDSHAKE_AGE" ]; then
    echo "  OK    last WireGuard handshake ${AGE}s ago (limit ${MAX_HANDSHAKE_AGE}s)"
  else
    echo "  FAIL  last WireGuard handshake ${AGE}s ago (limit ${MAX_HANDSHAKE_AGE}s)"
    TUNNEL_OK=0
  fi
fi

if docker exec $A ping -c1 -W2 10.100.100.2 >/dev/null 2>&1; then
  echo "  OK    far end of the tunnel answers ping"
else
  echo "  FAIL  far end of the tunnel does not answer ping"
  TUNNEL_OK=0
fi

echo "== Canaries (a marked message sent through the whole path)"

TS=$(date +%s)
PORT=$((20000 + TS % 10000))

# Canary 1: a plain syslog message from fw-site-a (tests rsyslog, tunnel, collector)
docker exec $A logger -t healthcheck "canary-$TS" 2>/dev/null
# Canary 2: a blocked connection from pc1 to pc3 on a unique port (tests the firewall
# log chain as well: nftables log rule -> NFLOG -> ulogd -> syslog -> tunnel -> collector)
docker exec $PC1 sh -c "echo canary | nc -w 1 192.0.2.130 $PORT" >/dev/null 2>&1
sleep 3

if docker exec $S grep -q "canary-$TS" $LOGFILE 2>/dev/null; then
  echo "  OK    syslog canary arrived at the collector"
else
  echo "  FAIL  syslog canary did not arrive at the collector"
  SYSLOG_OK=0
fi

if docker exec $S sh -c "grep FWA-DROP-FORWARD $LOGFILE 2>/dev/null | grep -q 'DPT=$PORT '"; then
  echo "  OK    firewall-event canary arrived at the collector"
else
  echo "  FAIL  firewall-event canary did not arrive at the collector"
  EVENT_OK=0
fi

echo "== Diagnosis"
if [ $TUNNEL_OK -eq 0 ]; then
  echo "  The tunnel is broken or stale, so logs from Site A are not reaching Site B."
  echo "  See RUNBOOK.md, failure mode 1."
elif [ $SYSLOG_OK -eq 0 ]; then
  echo "  The tunnel is up, but messages are not being recorded at the collector."
  echo "  See RUNBOOK.md, failure mode 2."
elif [ $EVENT_OK -eq 0 ]; then
  echo "  Syslog works, but firewall events are not being captured."
  echo "  See RUNBOOK.md, failure mode 3."
else
  echo "  Everything is healthy."
  exit 0
fi
exit 1
