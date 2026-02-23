# smarthomeserver

Docker Swarm stacks for homelab services running on Intel NUCs, integrated with TrueNAS for storage and media applications.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      TrueNAS Server                         │
│  Plex, Download clients, Home Assistant, TrueNAS Apps       │
│  NFS: /mnt/newton/media (192.168.0.196)                     │
└──────────────────────────┬──────────────────────────────────┘
                           │ NFS
┌──────────────────────────┴──────────────────────────────────┐
│                    Docker Swarm Cluster                      │
│  ┌───────────────────┐          ┌───────────────────┐       │
│  │   nuc8-1 (mgr)    │          │   nuc8-2 (wkr)    │       │
│  │  Media (light),   │          │  Sonarr, Radarr,  │       │
│  │  Security         │          │  Prowlarr,        │       │
│  │                   │          │  TeslaMate        │       │
│  └───────────────────┘          └───────────────────┘       │
│  Shared: AdGuard Home (x2), Nginx Proxy Manager             │
└─────────────────────────────────────────────────────────────┘
```

## Stacks

### tier1.yaml - Core Infrastructure
| Service | Description |
|---------|-------------|
| Nginx Proxy Manager | Reverse proxy and SSL certificate management (1 replica, pinned to nuc8-1) |

### adguard-standalone.yaml - DNS (standalone, not Swarm)
| Service | Description |
|---------|-------------|
| AdGuard Home (x2) | DNS ad-blocking with host networking; managed via keepalived VIP failover |

### security.yaml - Security
| Service | Description |
|---------|-------------|
| cloudflared | Cloudflare Tunnel — routes external traffic in without open WAN ports |
| crowdsec | Lightweight IPS — parses NPM logs and bans malicious IPs via iptables bouncer |

### media.yaml - Media Management
| Service | Description |
|---------|-------------|
| Overseerr | Request management for Plex |
| Radarr | Movie management |
| Sonarr | TV show management |
| Lidarr | Music management |
| Readarr | Book management |
| Mylar3 | Comic management |
| Prowlarr | Indexer management |
| Bazarr | Subtitle management |
| Tautulli | Plex statistics |
| Komga | Comic/manga server |
| Recyclarr | TRaSH guides sync for Radarr/Sonarr |
| cross-seed | Cross-seeding automation |
| Kometa | Plex metadata management |
| Maintainerr | Plex library maintenance |
| Epic Games | Free games claimer |

### teslamate.yaml - Tesla Vehicle Tracking
| Service | Description |
|---------|-------------|
| TeslaMate | Tesla data logging |
| PostgreSQL | TeslaMate database |
| Grafana | TeslaMate dashboards |
| Mosquitto | MQTT broker |

### docker-compose.yaml - Tesla Integration
| Service | Description |
|---------|-------------|
| Tesla HTTP Proxy | Tesla Fleet API proxy for Home Assistant |

## Setup

### Prerequisites
- Docker Swarm initialized across nodes
- TrueNAS NFS share accessible
- macvlan networks created for AdGuard instances

### Environment
Copy `.env.orig` to `.env` and configure:
```bash
DATADIR=/mnt/dockerData      # Shared Docker data
SERVARRDIR=/servarrData/     # Local *arr app configs
TZ=America/Chicago
PUID=1000
PGID=1001
```

### Deploy Stacks
All stack commands run on **nuc8-1** (Swarm manager) from `~/smarthomemanager/`. Use docker-compose to process `.env` variables before deploying:
```bash
docker-compose -f tier1.yaml config | docker stack deploy -c - tier1
docker-compose -f media.yaml config | docker stack deploy -c - media
docker-compose -f security.yaml config | docker stack deploy -c - security
docker-compose -f teslamate.yaml config | docker stack deploy -c - teslamate
docker-compose -f docker-compose.yaml config | docker stack deploy -c - tesla
```

AdGuard Home is managed separately (not a Swarm stack):
```bash
# On each node
docker-compose -f adguard-standalone.yaml up -d
```

## Network Setup

AdGuard Home uses host networking with keepalived Virtual IP (VIP) failover. See `keepalived/README.md` for setup details.

The main Docker Swarm overlay network `smarthomeserver` must be created before deploying stacks:
```bash
docker network create --driver overlay --attachable smarthomeserver
```

## Data Paths

| Path | Location | Purpose |
|------|----------|---------|
| `/mnt/dockerData` | Shared | General container data |
| `/servarrData` | Local (both nodes) | *arr app configurations (SQLite — must be local disk) |
| `/docker-binds/teslamate` | Local (nuc8-2) | TeslaMate data |
| NFS mount | TrueNAS | Media files |

## Useful Commands

### Deploy with Environment Variables
Docker stack deploy doesn't read `.env` files. Use docker-compose v1 to process variables:
```bash
docker-compose -f media.yaml config | docker stack deploy -c - media
```

### Force Update Service Images
Swarm pins image digests. Force pull fresh images when upstream updates:
```bash
docker service update --image lscr.io/linuxserver/sonarr:latest --force media_sonarr
```

### Debug Failing Services
Check task history with full error messages:
```bash
docker service ps media_sonarr --no-trunc
```

Check service logs:
```bash
docker service logs media_sonarr --tail 50
```

### Test Internal Service Connectivity
```bash
docker run --rm --network smarthomeserver curlimages/curl:latest http://sonarr:8989/
```

### Inspect Service Configuration
Check pinned image digest:
```bash
docker service inspect media_sonarr --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}'
```

Check mount configuration:
```bash
docker service inspect media_sonarr --format '{{json .Spec.TaskTemplate.ContainerSpec.Mounts}}' | jq .
```

### Scale Services
```bash
docker service scale media_sonarr=0  # Stop
docker service scale media_sonarr=1  # Start
```

### Remove Orphaned Services
Services not in YAML but still running from previous deploys:
```bash
docker service rm media_calibre
```
