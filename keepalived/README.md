# Keepalived Configuration for AdGuard Home

This directory contains the keepalived configuration for high-availability DNS
using AdGuard Home with Virtual IP (VIP) failover.

## Architecture

```
     VIP1: 192.168.0.253        VIP2: 192.168.0.254
              │                          │
  ┌───────────▼──┐                ┌──────▼────────┐
  │    nuc8-1    │                │    nuc8-2     │
  │   AdGuard    │                │   AdGuard     │
  │ MASTER(.253) │                │ MASTER(.254)  │
  │ BACKUP(.254) │                │ BACKUP(.253)  │
  └──────────────┘                └───────────────┘
```

Each node is MASTER for one VIP and BACKUP for the other. If a node or its
AdGuard instance fails, the other node takes over both VIPs.

## Files

- `setup.sh` - Installation script (run with sudo on each node)
- `check_adguard.sh` - Health check script (tests DNS resolution)
- `keepalived-nuc8-1.conf` - Keepalived config for nuc8-1
- `keepalived-nuc8-2.conf` - Keepalived config for nuc8-2

## Initial Setup

Run on each node:

```bash
# From the smarthomeserver directory
sudo ./keepalived/setup.sh nuc8-1  # on nuc8-1
sudo ./keepalived/setup.sh nuc8-2  # on nuc8-2
```

## How Failover Works

1. **Normal operation**:
   - nuc8-1 owns 192.168.0.253 (MASTER), nuc8-2 owns 192.168.0.254 (MASTER)
   - Both AdGuard instances serve DNS

2. **AdGuard fails on one node**:
   - Health check fails (`nslookup google.com 127.0.0.1`)
   - Priority drops by 20 (configured via `weight -20`)
   - Other node becomes MASTER for that VIP
   - Failover happens within ~15 seconds (3 failures × 5 second interval)

3. **Node dies completely**:
   - VRRP advertisements stop
   - Other node promotes to MASTER within ~3 seconds

4. **Recovery**:
   - Health check passes, priority restored
   - Original MASTER reclaims VIP (preemption enabled by default)

## Monitoring Commands

```bash
# Check which node owns which VIP
ip addr show eno1 | grep "192.168.0.25"

# Check keepalived status
sudo systemctl status keepalived

# Watch keepalived logs (shows failover events)
sudo journalctl -u keepalived -f

# Test DNS on both VIPs
dig @192.168.0.253 google.com +short
dig @192.168.0.254 google.com +short
```

## Testing Failover

```bash
# On nuc8-1, stop AdGuard to trigger failover
docker service scale tier1_adguard1=0

# Watch VIP move to nuc8-2
ssh nuc8-2 "ip addr show eno1 | grep 192.168.0.25"

# Restore AdGuard
docker service scale tier1_adguard1=1

# VIP should return to nuc8-1 after health check passes
```

## Troubleshooting

### VIP not appearing
```bash
# Check keepalived is running
sudo systemctl status keepalived

# Check for errors in logs
sudo journalctl -u keepalived -e

# Verify interface name matches config
ip link show
```

### Health check failing
```bash
# Test manually
nslookup google.com 127.0.0.1

# Check AdGuard is listening on localhost
ss -ulnp | grep :53
```

### Both nodes claim same VIP (split-brain)
```bash
# Check VRRP traffic is flowing (should see multicast)
sudo tcpdump -i eno1 vrrp

# Verify authentication passwords match on both nodes
grep auth_pass /etc/keepalived/keepalived.conf
```

## Firewall Considerations

With host networking, AdGuard uses the host's primary IP (not the VIP) as the
source for outbound queries to upstream DNS servers:

- nuc8-1: outbound from 192.168.0.101
- nuc8-2: outbound from 192.168.0.26

If you have firewall rules restricting outbound DNS (port 53), ensure these
host IPs are allowed. The VIPs (192.168.0.253/254) are only used for inbound
client queries.

## Rollback to Macvlan

If you need to revert to the previous macvlan setup:

```bash
# Stop and disable keepalived on both nodes
sudo systemctl stop keepalived
sudo systemctl disable keepalived

# Revert tier1.yaml
git checkout tier1.yaml

# Recreate macvlan networks and redeploy
# (see previous git history for macvlan network creation commands)
```

## Configuration Reference

| Parameter | Value | Description |
|-----------|-------|-------------|
| `virtual_router_id` | 53, 54 | Unique ID per VIP (must match on both nodes) |
| `priority` | 100 (MASTER), 90 (BACKUP) | Higher wins election |
| `advert_int` | 1 | VRRP advertisement interval (seconds) |
| `weight` | -20 | Priority reduction on health check failure |
| `fall` | 3 | Failures before marking unhealthy |
| `rise` | 2 | Successes before marking healthy |
| `interval` | 5 | Health check interval (seconds) |
