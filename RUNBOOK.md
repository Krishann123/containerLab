# Runbook: Secure Log Transport Lab

How to tell whether the log pipeline is healthy, and how to fix its three most likely failures. Run the commands from the repo root in the Codespaces terminal, after loading the shortcuts:

```bash
source scripts/shortcuts.sh
```

The pipeline being watched:

```
fw-site-a (nftables log -> NFLOG -> ulogd -> syslog -> rsyslog) -> WireGuard tunnel -> fw-site-b -> rsyslog collector
```

---

## 1. Monitor

Run the health check. It exits 0 when healthy and 1 when something is wrong, and it prints a diagnosis that points to a failure mode in this runbook:

```bash
sh scripts/healthcheck.sh
```

To watch continuously:

```bash
while true; do sh scripts/healthcheck.sh; sleep 60; done
```

| Check | What it proves | How fast it notices a break |
|---|---|---|
| `eth3` is up | The transit link is up | Instantly |
| WireGuard handshake is 180 s old or less | The tunnel session is alive | Slow: up to 3 minutes |
| Ping to `10.100.100.2` | Traffic crosses the tunnel | Instantly |
| Syslog canary | A marked message gets from `fw-site-a` to the collector | About 3 seconds |
| Firewall-event canary | A blocked connection becomes a log line on the collector | About 3 seconds |

The canaries matter most. If the transit link is cut, `wg0` still shows as UP and `wg show` still lists the peer, so the interface state alone says nothing. The only convincing proof that logs arrive is a marked message that arrives.

### Reading the result

| Tunnel checks | Syslog canary | Firewall-event canary | Meaning | Go to |
|---|---|---|---|---|
| FAIL | any | any | Tunnel or transit link problem | 3.1 |
| OK | FAIL | any | The collector side is not recording | 3.2 |
| OK | OK | FAIL | Firewall events are not being captured | 3.3 |
| OK | OK | OK | Healthy | none |

### Do not test with

Do not ping `203.0.113.2` from `fw-site-a`. The firewall's output rules allow only WireGuard (UDP 51820) to that address, so a failed ping proves nothing. Use `ip link show eth3` and `wg show` instead.

### Reading `ps` inside a container

Lines like `[rsyslogd]` are dead processes left over from restarts and can be ignored. A service is running only if its name appears without brackets, such as `rsyslogd` or `ulogd`.

---

## 2. What to watch for in a real deployment

The lab uses an active canary because it is simple. A production setup would add:

- **A heartbeat:** `fw-site-a` sends a message every 30 seconds, and an alert fires on the collector when none has arrived for 90 seconds. This detects a break without having to inject test traffic.
- **A handshake-age alert** at 180 seconds, and a tunnel-ping alert.
- **Collector disk space.** There is no log rotation in the lab, so the collector's disk fills up eventually. Check with `docker exec $S df -h /var/log`.
- **The firewall's drop counters** (`docker exec $A nft list ruleset`). Drop logging is limited to 10 per second per chain, so the counters show the true volume during a flood.

---

## 3. The three most likely failures

### 3.1 The tunnel or transit link is down

**Symptom:** the health check fails in the Tunnel section. Logs from Site A stop arriving.

**What happens to logs:** messages generated during the outage are lost. They are sent as UDP, and nothing is queued to disk. The firewall keeps enforcing its rules, but nobody sees the events.

**Confirm:**

```bash
docker exec $A ip link show eth3       # should say "state UP"
docker exec $B ip link show eth1       # should say "state UP"
docker exec $A wg show                 # "latest handshake" should be recent, transfer counters growing
docker exec $B wg show
docker exec $A ip route | grep 198.51.100.0   # should list "dev wg0"
```

**Fix, in order:**

1. If a transit interface is down, bring it up. WireGuard reconnects by itself a few seconds later:
   ```bash
   docker exec $A ip link set eth3 up
   docker exec $B ip link set eth1 up
   ```
2. If `wg0` itself was brought down, bringing it up is not enough, because its routes disappear when it goes down. Re-add them:
   ```bash
   docker exec $A ip link set wg0 up
   docker exec $A ip route replace 198.51.100.0/24 dev wg0
   docker exec $B ip link set wg0 up
   docker exec $B ip route replace 192.0.2.0/24 dev wg0
   ```
3. If the handshake never completes, the keys or `allowed-ips` are wrong. Rebuild (section 4).
4. Run the health check to confirm.

**Note:** while the route into `wg0` is missing, `fw-site-a` would try to send the logs out of its management interface. Its default-deny output rules block that and count it as `FWA-DROP-OUTPUT`, so logs do not leak outside the tunnel. The firewall fails closed.

### 3.2 The collector is not recording

**Symptom:** the Tunnel section is OK, but the syslog canary fails (and usually the firewall-event canary too).

**Likely causes:** rsyslog crashed or stopped on the collector, the Site B firewall lost its UDP 514 rule, or the collector's disk is full.

**Confirm:**

```bash
docker exec $S ps                                        # look for "rsyslogd" without brackets
docker exec $S netstat -lun | grep 514                   # the collector should be listening on UDP 514
docker exec $B nft list chain inet filter forward        # should show the "udp dport 514" accept rule
docker exec $S df -h /var/log                            # free space
docker exec $S rsyslogd -N1                              # config check
```

**Fix:**

```bash
docker exec $S sh -c 'pkill rsyslogd; sleep 1; rsyslogd'
```

If the Site B rule is missing, rebuild (section 4).

### 3.3 Firewall events are not being captured

**Symptom:** the Tunnel section and the syslog canary are OK, but the firewall-event canary fails. This one is silent: the firewall still enforces its rules, but its events are not logged, which is a blind spot.

**Likely causes:** `ulogd` stopped, or the firewall rules were reloaded without the `log` rules.

**Confirm:**

```bash
docker exec $A ps                                   # look for "ulogd" without brackets
docker exec $A cat /var/log/ulogd.log               # ulogd's own errors
docker exec $A nft list ruleset | grep -c 'group 1' # should print 4 (input, forward x2, output)
```

**Fix:**

```bash
docker exec $A sh -c 'pkill ulogd; sleep 1; ulogd -d -c /etc/ulogd.conf'
```

If the count is not 4, reload the rules:

```bash
docker exec $A nft -f /etc/fw-site-a.nft
```

---

## 4. Last resort: rebuild everything

```bash
sh scripts/rebuild.sh
```

This destroys and recreates the whole lab, so it also deletes every log the collector has received. That is acceptable in the lab. A production collector would keep its logs on persistent storage. Also rebuild after any codespace restart, because the running lab does not survive one.
