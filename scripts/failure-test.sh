#!/bin/sh
# Failure test: cut the transit link between the sites, show what breaks, what is lost
# and how it is detected, then restore the link and time the recovery.
# Usage: sh scripts/failure-test.sh [outage seconds, default 20]
# To keep the output as evidence:  sh scripts/failure-test.sh | tee failure-test-output.txt
# It tests short outages (well under 3 minutes). WireGuard behaves differently once its
# session has expired, so longer outages are a different experiment.
cd "$(dirname "$0")/.." || exit 1

P=clab-bank-sec-lab
A=$P-fw-site-a
S=$P-rsyslog-server
PC1=$P-pc1
LOGFILE=/var/log/remote/fw-site-a/syslog.log
OUTAGE=${1:-20}

count_marks() {
  n=$(docker exec $S grep -c "$MARK" $LOGFILE 2>/dev/null)
  echo "${n:-0}"
}

echo "### 1. Baseline: is the pipeline healthy before we break it?"
if ! sh scripts/healthcheck.sh; then
  echo
  echo "The baseline is not healthy. Fix that first (try: sh scripts/rebuild.sh)."
  exit 1
fi

echo
echo "### 2. Cut the transit link (fw-site-a eth3 down) at $(date +%T)"
docker exec $A ip link set eth3 down
T0=$(date +%s)
MARK="outage-$T0"

echo
echo "### 3. While the link is down, generate 5 log messages and 1 firewall event"
i=1
while [ $i -le 5 ]; do
  docker exec $A logger -t failure-test "$MARK msg $i"
  i=$((i + 1))
  sleep 1
done
PORT=$((30000 + T0 % 10000))
docker exec $PC1 sh -c "echo during-outage | nc -w 1 192.0.2.130 $PORT" >/dev/null 2>&1
echo "  sent 5 syslog messages marked '$MARK' and 1 blocked connection (port $PORT)"
echo "  wg0 still looks like this:"
docker exec $A ip link show wg0 | head -n 1 | sed 's/^/    /'

echo
echo "### 4. Detection: the health check while the link is down"
sh scripts/healthcheck.sh

echo
echo "### 5. Wait out the rest of the outage"
ELAPSED=$(( $(date +%s) - T0 ))
if [ $ELAPSED -lt $OUTAGE ]; then
  sleep $((OUTAGE - ELAPSED))
fi
echo "  outage lasted about $(( $(date +%s) - T0 ))s"
echo "  outage messages on the collector so far: $(count_marks) of 5"

echo
echo "### 6. Restore the link and time the recovery"
docker exec $A ip link set eth3 up
T1=$(date +%s)
RECOVERED=0
n=0
while [ $n -lt 60 ]; do
  if docker exec $A ping -c1 -W1 10.100.100.2 >/dev/null 2>&1; then
    RECOVERED=1
    break
  fi
  n=$((n + 1))
  sleep 1
done
if [ $RECOVERED -eq 1 ]; then
  echo "  the tunnel answered again $(( $(date +%s) - T1 ))s after the link came back (no manual steps on wg0)"
else
  echo "  the tunnel did NOT recover within 60s. See RUNBOOK.md, failure mode 1."
fi

echo
echo "### 7. What was lost?"
sleep 10
echo "  sent during the outage:     5 syslog messages"
echo "  arrived after recovery:     $(count_marks) of 5"
docker exec $A logger -t failure-test "recovered-$T0"
sleep 2
if docker exec $S grep -q "recovered-$T0" $LOGFILE 2>/dev/null; then
  echo "  new messages flow again:    yes"
else
  echo "  new messages flow again:    NO"
fi

echo
echo "### 8. Health check after recovery"
sh scripts/healthcheck.sh
