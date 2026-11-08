#!/bin/sh
# One-command rebuild. Run from the repo root: sh scripts/rebuild.sh
set -e
cd "$(dirname "$0")/.."
TOPO=bank-sec-lab.clab.yml
P=clab-bank-sec-lab
A=$P-fw-site-a; B=$P-fw-site-b; S=$P-rsyslog-server

echo "## 1. host bridges + deploy (kind: bridge needs the bridge to exist first)"
for b in sw-app sw-db; do
  sudo ip link add $b type bridge 2>/dev/null || true
  sudo ip link set $b up
done
sudo containerlab deploy -t $TOPO --reconfigure

echo "## 2. install tools"
for n in $A $B; do
  docker exec $n apk add --no-cache iproute2 nftables wireguard-tools rsyslog >/dev/null
done
docker exec $S apk add --no-cache iproute2 rsyslog >/dev/null

echo "## 3. addresses and forwarding (the underlay)"
docker exec $A sh -c '
  for i in eth1 eth2 eth3; do ip link set $i up; done
  ip addr add 192.0.2.126/25 dev eth1
  ip addr add 192.0.2.254/25 dev eth2
  ip addr add 203.0.113.1/30 dev eth3
  sysctl -qw net.ipv4.ip_forward=1'
docker exec $B sh -c '
  for i in eth1 eth2; do ip link set $i up; done
  ip addr add 203.0.113.2/30 dev eth1
  ip addr add 198.51.100.254/24 dev eth2
  sysctl -qw net.ipv4.ip_forward=1'
docker exec $S sh -c '
  ip link set eth1 up
  ip addr add 198.51.100.10/24 dev eth1
  ip route add 10.100.100.0/30 via 198.51.100.254
  ip route add 192.0.2.0/24 via 198.51.100.254'

docker exec $A ping -c2 -W1 203.0.113.2 >/dev/null \
  || { echo "UNDERLAY BROKEN: FW-A cannot reach FW-B"; exit 1; }
echo "underlay OK"

echo "## 4. WireGuard (fresh keys every rebuild, so no stale peers)"
for n in $A $B; do
  docker exec $n sh -c 'mkdir -p /etc/wireguard; umask 077; wg genkey > /etc/wireguard/priv; wg pubkey < /etc/wireguard/priv > /etc/wireguard/pub'
done
PUB_A=$(docker exec $A cat /etc/wireguard/pub)
PUB_B=$(docker exec $B cat /etc/wireguard/pub)

docker exec $A sh -c "
  ip link add wg0 type wireguard
  ip addr add 10.100.100.1/30 dev wg0
  wg set wg0 listen-port 51820 private-key /etc/wireguard/priv \
    peer $PUB_B endpoint 203.0.113.2:51820 \
    allowed-ips 10.100.100.2/32,198.51.100.0/24 persistent-keepalive 25
  ip link set wg0 up
  ip route add 198.51.100.0/24 dev wg0"

docker exec $B sh -c "
  ip link add wg0 type wireguard
  ip addr add 10.100.100.2/30 dev wg0
  wg set wg0 listen-port 51820 private-key /etc/wireguard/priv \
    peer $PUB_A allowed-ips 10.100.100.1/32,192.0.2.0/24
  ip link set wg0 up
  ip route add 192.0.2.0/24 dev wg0"

echo "## 5. nftables on FW-B (flush first, so reruns never duplicate rules)"
docker exec -i $B nft -f - <<'NFT'
flush ruleset
table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;
    ct state established,related accept
    iifname "lo" accept
    iifname "eth1" udp dport 51820 accept
    iifname "wg0" icmp type echo-request accept
  }
  chain forward {
    type filter hook forward priority 0; policy drop;
    ct state established,related accept
    iifname "wg0" oifname "eth2" ip saddr 10.100.100.1 ip daddr 198.51.100.10 udp dport 514 accept
  }
}
NFT

echo "## 6. rsyslog"
docker cp configs/rsyslog-server.conf $S:/etc/rsyslog.conf
docker exec $S rsyslogd
docker exec -i $A sh -c 'cat > /etc/rsyslog.conf' <<'RS'
module(load="imuxsock")
*.* @198.51.100.10:514
RS
docker exec $A rsyslogd

echo "## 7. test"
sleep 3
docker exec $A logger -t rebuild-test "hello from fw-site-a"
sleep 2
docker exec $S sh -c 'find /var/log/remote -type f; cat /var/log/remote/*/syslog.log'
