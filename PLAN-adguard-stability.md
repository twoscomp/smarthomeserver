# AdGuard Stability Improvement Plan

## Status: COMPLETED (2025-02-12)

## Selected Approach: Keepalived with Dual VIP (Active/Active)

Replace Docker Swarm macvlan networking with keepalived-managed Virtual IPs for robust failover.

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

**Benefits over macvlan:**
- Battle-tested VRRP protocol (used in enterprise networking)
- Clear failover behavior with logging
- No Docker IPAM state corruption
- Host can communicate with its own AdGuard instance
- Standard Linux networking tools for troubleshooting

---

## Implementation Steps

### Phase 1: Install Keepalived (Both Nodes)

```bash
# On both nuc8-1 and nuc8-2
sudo apt update && sudo apt install -y keepalived
```

### Phase 2: Create Health Check Script (Both Nodes)

```bash
sudo tee /etc/keepalived/check_adguard.sh << 'EOF'
#!/bin/bash
# Check if AdGuard is responding to DNS queries
nslookup google.com 127.0.0.1 > /dev/null 2>&1
exit $?
EOF

sudo chmod +x /etc/keepalived/check_adguard.sh
```

### Phase 3: Configure Keepalived

#### nuc8-1 Configuration
```bash
sudo tee /etc/keepalived/keepalived.conf << 'EOF'
global_defs {
    router_id nuc8-1
    script_user root
    enable_script_security
}

# Health check for local AdGuard
vrrp_script check_adguard {
    script "/etc/keepalived/check_adguard.sh"
    interval 5
    weight -20
    fall 3
    rise 2
}

# VIP 192.168.0.253 - nuc8-1 is MASTER
vrrp_instance VI_ADGUARD1 {
    state MASTER
    interface eno1
    virtual_router_id 53
    priority 100
    advert_int 1

    authentication {
        auth_type PASS
        auth_pass adguard253
    }

    virtual_ipaddress {
        192.168.0.253/24
    }

    track_script {
        check_adguard
    }
}

# VIP 192.168.0.254 - nuc8-1 is BACKUP
vrrp_instance VI_ADGUARD2 {
    state BACKUP
    interface eno1
    virtual_router_id 54
    priority 90
    advert_int 1

    authentication {
        auth_type PASS
        auth_pass adguard254
    }

    virtual_ipaddress {
        192.168.0.254/24
    }

    track_script {
        check_adguard
    }
}
EOF
```

#### nuc8-2 Configuration
```bash
sudo tee /etc/keepalived/keepalived.conf << 'EOF'
global_defs {
    router_id nuc8-2
    script_user root
    enable_script_security
}

# Health check for local AdGuard
vrrp_script check_adguard {
    script "/etc/keepalived/check_adguard.sh"
    interval 5
    weight -20
    fall 3
    rise 2
}

# VIP 192.168.0.253 - nuc8-2 is BACKUP
vrrp_instance VI_ADGUARD1 {
    state BACKUP
    interface eno1
    virtual_router_id 53
    priority 90
    advert_int 1

    authentication {
        auth_type PASS
        auth_pass adguard253
    }

    virtual_ipaddress {
        192.168.0.253/24
    }

    track_script {
        check_adguard
    }
}

# VIP 192.168.0.254 - nuc8-2 is MASTER
vrrp_instance VI_ADGUARD2 {
    state MASTER
    interface eno1
    virtual_router_id 54
    priority 100
    advert_int 1

    authentication {
        auth_type PASS
        auth_pass adguard254
    }

    virtual_ipaddress {
        192.168.0.254/24
    }

    track_script {
        check_adguard
    }
}
EOF
```

### Phase 4: Update tier1.yaml

Replace macvlan networking with host networking and node constraints:

```yaml
version: "3.9"

x-env: &env
  environment:
    - PUID=${PUID}
    - PGID=${PGID}
    - TZ=${TZ}

networks:
  default:
    name: smarthomeserver
    external: true

volumes:
  adguard1-work:
  adguard2-work:

services:
  adguard1:
    <<: *env
    image: adguard/adguardhome:latest
    restart: unless-stopped
    network_mode: host
    volumes:
      - "adguard1-work:/opt/adguardhome/work"
      - "${DATADIR}/adguard/confdir:/opt/adguardhome/conf"
    deploy:
      placement:
        constraints:
          - node.hostname == nuc8-1
    healthcheck:
      test: ["CMD", "nslookup", "google.com", "127.0.0.1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s

  adguard2:
    <<: *env
    image: adguard/adguardhome:latest
    restart: unless-stopped
    network_mode: host
    volumes:
      - "adguard2-work:/opt/adguardhome/work"
      - "${DATADIR}/adguard/confdir:/opt/adguardhome/conf"
    deploy:
      placement:
        constraints:
          - node.hostname == nuc8-2
    healthcheck:
      test: ["CMD", "nslookup", "google.com", "127.0.0.1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s

  nginx-proxy-manager:
    # ... (unchanged)
```

### Phase 5: Cleanup Macvlan Networks

```bash
# Scale down AdGuard services
docker service scale tier1_adguard1=0 tier1_adguard2=0

# Remove macvlan swarm networks
docker network rm adguard-mvl-1 adguard-mvl-2

# Remove config networks (on each node)
docker network rm adguard-mvl-config-1 adguard-mvl-config-2 adguard-mvl-config-3
```

### Phase 6: Deploy and Enable

```bash
# Start keepalived on both nodes
sudo systemctl enable keepalived
sudo systemctl start keepalived

# Deploy updated tier1 stack
docker-compose -f tier1.yaml config | docker stack deploy -c - tier1

# Verify
ip addr show eno1 | grep "192.168.0.25"
dig @192.168.0.253 google.com +short
dig @192.168.0.254 google.com +short
```

---

## How Failover Works

1. **Normal operation**:
   - nuc8-1 owns 192.168.0.253 (MASTER), nuc8-2 owns 192.168.0.254 (MASTER)
   - Both AdGuard instances serve DNS

2. **nuc8-1 AdGuard fails**:
   - Health check fails, priority drops by 20 (100→80)
   - nuc8-2 (priority 90) becomes MASTER for .253
   - nuc8-2 now owns both VIPs, serves all DNS traffic

3. **nuc8-1 recovers**:
   - Health check passes, priority restored to 100
   - nuc8-1 reclaims .253 (preemption)

4. **nuc8-1 node dies completely**:
   - VRRP advertisements stop
   - nuc8-2 promotes to MASTER for .253 within ~3 seconds

---

## Monitoring Commands

```bash
# Check VIP ownership
ip addr show eno1 | grep "192.168.0.25"

# Check keepalived status
sudo systemctl status keepalived

# View keepalived logs
sudo journalctl -u keepalived -f

# Test failover (temporarily stop AdGuard)
docker service scale tier1_adguard1=0
# Watch VIP move to other node
ip addr show eno1  # on nuc8-2, should now show .253

# Test DNS on both VIPs
dig @192.168.0.253 google.com +short
dig @192.168.0.254 google.com +short
```

---

## Rollback Plan

If issues occur, revert to macvlan:

```bash
# Stop keepalived
sudo systemctl stop keepalived
sudo systemctl disable keepalived

# Recreate macvlan networks
# ... (previous macvlan setup commands)

# Revert tier1.yaml to use macvlan networks
git checkout tier1.yaml

# Redeploy
docker-compose -f tier1.yaml config | docker stack deploy -c - tier1
```
