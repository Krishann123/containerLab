#!/bin/sh
# Zones step: give the four PCs their addresses, then load the Site A firewall rules.
# Usage: sh scripts/zones.sh   (scripts/rebuild.sh calls it automatically)
# Safe to run again: addresses are flushed and replaced, and the nftables
# file starts with "flush ruleset".
set -e
cd "$(dirname "$0")/.."

P=clab-bank-sec-lab
A=$P-fw-site-a
FAILED=0

setup_pc() {
  # usage: setup_pc <node> <address/prefix> <gateway>
  docker exec "$P-$1" sh -c "
    ip link set eth1 up
    ip addr flush dev eth1
    ip addr add $2 dev eth1
    ip route replace default via $3"
  echo "  $1: $2, gateway $3"
}

expect() {
  # usage: expect <pass|block> <node> <ping target> <description>
  if docker exec "$P-$2" ping -c1 -W1 "$3" >/dev/null 2>&1; then
    result=pass
  else
    result=block
  fi
  if [ "$result" = "$1" ]; then
    echo "  OK      $4"
  else
    echo "  FAILED  $4 (expected $1, got $result)"
    FAILED=1
  fi
}

echo "## 1. PC addresses (the firewall is each zone's default gateway)"
setup_pc pc1 192.0.2.10/25  192.0.2.126
setup_pc pc2 192.0.2.11/25  192.0.2.126
setup_pc pc3 192.0.2.130/25 192.0.2.254
setup_pc pc4 192.0.2.131/25 192.0.2.254

echo "## 2. Site A firewall rules"
docker cp configs/fw-site-a.nft "$A:/etc/fw-site-a.nft"
docker exec "$A" nft -f /etc/fw-site-a.nft
echo "  rules loaded"

echo "## 3. Quick checks"
expect pass  pc1 192.0.2.126 "pc1 reaches its gateway (fw-site-a, App side)"
expect pass  pc3 192.0.2.254 "pc3 reaches its gateway (fw-site-a, DB side)"
expect pass  pc1 192.0.2.11  "pc1 reaches pc2 (same zone, stays on the switch)"
expect block pc1 192.0.2.130 "pc1 cannot ping pc3 (blocked by the firewall)"
expect pass  fw-site-a 10.100.100.2 "fw-site-a reaches the far end of the tunnel"

if [ "$FAILED" -ne 0 ]; then
  echo "One or more checks failed. See 'If something fails' in the guide."
  exit 1
fi
echo "All checks passed."
