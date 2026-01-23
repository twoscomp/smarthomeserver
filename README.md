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
│  │      nuc8-1       │          │      nuc8-2       │       │
│  │  Media, Monitor,  │          │    TeslaMate      │       │
│  │  Tesla HTTP Proxy │          │                   │       │
│  └───────────────────┘          └───────────────────┘       │
│  Shared: AdGuard Home (x2), Nginx Proxy Manager             │
└─────────────────────────────────────────────────────────────┘
```

## Stacks

### tier1.yaml - Core Infrastructure
| Service | Description |
|---------|-------------|
| AdGuard Home (x2) | DNS ad-blocking on macvlan networks (appear as physical devices) |
| Nginx Proxy Manager | Reverse proxy and SSL certificate management |

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

### monitoring.yaml - Observability
| Service | Description |
|---------|-------------|
| Grafana | Dashboards and visualization |
| Prometheus | Metrics collection |
| Graphite Exporter | Graphite metrics ingestion |

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
```bash
docker stack deploy -c tier1.yaml tier1
docker stack deploy -c media.yaml media
docker stack deploy -c monitoring.yaml monitoring
docker stack deploy -c teslamate.yaml teslamate
docker stack deploy -c docker-compose.yaml tesla
```

## Network Setup

AdGuard Home instances run on macvlan networks, allowing them to have dedicated IPs on the LAN. Create the networks before deploying:
```bash
docker network create -d macvlan \
  --subnet=192.168.0.0/24 \
  --gateway=192.168.0.1 \
  -o parent=eth0 \
  adguard-mvl-1
```

## Data Paths

| Path | Location | Purpose |
|------|----------|---------|
| `/mnt/dockerData` | Shared | General container data |
| `/servarrData` | Local (nuc8-1) | *arr app configurations |
| `/docker-binds/teslamate` | Local (nuc8-2) | TeslaMate data |
| NFS mount | TrueNAS | Media files |
