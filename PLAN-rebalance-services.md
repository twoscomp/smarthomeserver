# Plan: Rebalance Services Across nuc8-1 and nuc8-2

## Problem

nuc8-1 has a load average of ~15 on 4 cores. Almost the entire media stack is
hard-pinned there via YAML anchors (`x-deploy-nuc` / `x-lsio-nuc`) because the
*arr services store SQLite databases in `/servarrData/`, which is local disk on
nuc8-1 only.

SQLite cannot be hosted on GlusterFS or NFS due to file locking issues that
cause db locked/corruption errors. Configs must remain on local disk.

## Current Distribution

### nuc8-1 (14 tasks) — OVERLOADED
| Service             | CPU   | RAM    | Constraint         |
|---------------------|-------|--------|--------------------|
| media_sonarr        | 15.6% | 224MB  | SERVARRDIR (local) |
| media_prowlarr      | 12.6% | 244MB  | SERVARRDIR (local) |
| tier1_adguard1      | 9.1%  | 57MB   | DATADIR (gluster)  |
| media_radarr        | 0.3%  | 239MB  | SERVARRDIR (local) |
| media_overseerr     | 0.2%  | 128MB  | SERVARRDIR (local) |
| media_komga         | 0.2%  | 116MB  | SERVARRDIR (local) |
| media_readarr       | 0.1%  | 97MB   | SERVARRDIR (local) |
| media_lidarr        | 0.1%  | 83MB   | SERVARRDIR (local) |
| media_bazarr        | 0.2%  | 26MB   | SERVARRDIR (local) |
| media_mylar3        | 0.04% | 27MB   | SERVARRDIR (local) |
| media_tautulli      | 0.05% | 10MB   | SERVARRDIR (local) |
| media_recyclarr     | 0.01% | 5MB    | DATADIR (gluster)  |
| monitoring_prometheus | 0.7% | 70MB  | node.role==manager |

### nuc8-2 (13 tasks)
- teslamate stack (4 services, pinned to nuc8-2)
- monitoring_grafana, graphite_exporter
- media_cross-seed, epic-games, maintainerr, plex-meta-manager
- smarthomeserver_tesla-http-proxy
- tier1_adguard2, nginx-proxy-manager (x2)

## nuc8-2 Capacity Check

| Metric         | nuc8-1        | nuc8-2       | After rebalance (est.) |
|----------------|---------------|--------------|------------------------|
| Load avg       | 15.6          | 0.20         | ~8 / ~8                |
| RAM used       | 2.6GB (+1.3GB swap) | 1.8GB  | ~1.9GB / ~2.5GB        |
| RAM available  | 1.1GB         | 2.0GB        | ~1.8GB / ~1.3GB        |
| Swap used      | 1.3GB         | 147MB        | should drop on nuc8-1  |
| Container CPU  | ~39%          | ~16%         | ~11% / ~44%            |
| Tasks          | 14            | 13           | 11 / 16                |

nuc8-2 has ample headroom. No risk of overloading.

## Solution: Move Heavy Services to nuc8-2

Move the three heaviest *arr services to nuc8-2 by copying their config to
nuc8-2's local disk and re-pinning them.

### Services to Move

| Service        | CPU   | RAM   |
|----------------|-------|-------|
| sonarr         | 15.6% | 224MB |
| prowlarr       | 12.6% | 244MB |
| radarr         | 0.3%  | 239MB |

This offloads ~28% CPU and ~700MB RAM from nuc8-1.

### Prerequisites

Config dirs are owned by `apps:docker` (uid 568, gid 1001). `dlin` is in the
`docker` group so can read, but creating `/servarrData/` on nuc8-2 and writing
files as the correct owner requires sudo.

Add passwordless sudo on **nuc8-2**:
```bash
sudo visudo -f /etc/sudoers.d/claude-rebalance
```
```
dlin ALL=(ALL) NOPASSWD: /usr/bin/mkdir, /usr/bin/chown, /usr/bin/rsync
```

Add passwordless sudo on **nuc8-1** (for rsync to read as root):
```bash
sudo visudo -f /etc/sudoers.d/claude-rebalance
```
```
dlin ALL=(ALL) NOPASSWD: /usr/bin/rsync
```

### Steps

1. **Create `/servarrData/` on nuc8-2** with matching ownership/permissions:
   ```bash
   ssh nuc8-2 "sudo mkdir -p /servarrData && sudo chown apps:docker /servarrData && sudo chmod 2775 /servarrData"
   ```

2. **For each service (sonarr, prowlarr, radarr):**
   a. Scale down: `docker service scale media_<svc>=0`
   b. Rsync config to nuc8-2 preserving ownership:
      ```bash
      sudo rsync -avP /servarrData/<svc>/ --rsync-path="sudo rsync" nuc8-2:/servarrData/<svc>/
      ```
   c. Verify data integrity on nuc8-2 (file count, sizes, ownership match).

3. **Update `media.yaml`:**
   - Add new YAML anchors for nuc8-2:
     ```yaml
     x-deploy-nuc2: &deploy-nuc2
       deploy:
         placement:
           constraints:
             - node.hostname == nuc8-2

     x-lsio-nuc2: &lsio-nuc2
       environment:
         - PUID=568
         - PGID=1001
         - TZ=${TZ}
       deploy:
         placement:
           constraints:
             - node.hostname == nuc8-2
     ```
   - Change sonarr, prowlarr, radarr from `*lsio-nuc` to `*lsio-nuc2`.

4. **Redeploy media stack:**
   ```bash
   docker stack deploy -c media.yaml media
   ```

5. **Verify:**
   - All three services healthy on nuc8-2.
   - No SQLite errors in logs.
   - nuc8-1 load average drops.

6. **Cleanup:** Remove old config dirs from nuc8-1 `/servarrData/` once stable.

7. **Remove sudoers rules** once migration is complete:
   ```bash
   sudo rm /etc/sudoers.d/claude-rebalance
   ssh nuc8-2 "sudo rm /etc/sudoers.d/claude-rebalance"
   ```

## Phase 1 — COMPLETED

Moved sonarr, prowlarr, radarr to nuc8-2. Config dirs rsynced, media.yaml
updated with `*lsio-nuc2` anchors, stack redeployed. All three healthy.

## Phase 2 — IN PROGRESS

After Phase 1, nuc8-1 still showed high load (~13) due to memory pressure
(3.2GB used, 3.7GB swap). nuc8-2 was at load 0.77 with 1.8GB available.
Moving additional services to free RAM on nuc8-1.

### Services to Move

| Service        | RAM   | Storage    | Method                    |
|----------------|-------|------------|---------------------------|
| readarr        | 119MB | SERVARRDIR | rsync + re-pin (SQLite)   |
| overseerr      | 139MB | SERVARRDIR | rsync + re-pin (SQLite)   |
| grafana (mon.) | 102MB | DATADIR    | add nuc8-2 constraint only |

### Completed Steps

- [x] Scaled down media_readarr and media_overseerr
- [x] Rsynced overseerr config to nuc8-2 (51/51 files)
- [x] Rsynced readarr config to nuc8-2 (8745 files)

### Remaining Steps

1. **Update `media.yaml`:**
   - Change readarr from `*lsio-nuc` to `*lsio-nuc2`
   - Change overseerr from `*deploy-nuc` to `*deploy-nuc2`

2. **Update `monitoring.yaml`:**
   - Add nuc8-2 placement constraint to grafana:
     ```yaml
     deploy:
       placement:
         constraints:
           - node.hostname == nuc8-2
     ```

3. **Redeploy both stacks** (must use docker-compose to template env vars):
   ```bash
   docker-compose -f media.yaml config | docker stack deploy -c - media
   docker-compose -f monitoring.yaml config | docker stack deploy -c - monitoring
   ```

4. **Verify:**
   - readarr, overseerr, grafana all healthy on nuc8-2
   - No SQLite errors in readarr/overseerr logs
   - nuc8-1 load and swap usage decrease

5. **Cleanup:** Remove old config dirs from nuc8-1 once stable:
   ```bash
   sudo rm -rf /servarrData/overseerr /servarrData/readarr
   ```

6. **Update README.md** with final topology

## Post-Rebalance Distribution (after Phase 2)

### nuc8-1 (8 tasks)
- media: bazarr, komga, lidarr, mylar3, recyclarr, tautulli
- monitoring: prometheus
- floating: nginx-proxy-manager (1 replica), tesla-http-proxy

### nuc8-2 (19 tasks)
- media: sonarr, prowlarr, radarr, readarr, overseerr, cross-seed,
  epic-games, maintainerr, plex-meta-manager
- teslamate: database, grafana, mosquitto, teslamate
- monitoring: grafana, graphite_exporter
- floating: adguard1, adguard2, nginx-proxy-manager (1 replica)

## Notes

- The NFS media volume (TrueNAS) is network-mounted and works from either node.
- Only SQLite config dirs need local disk — this is why we rsync rather than
  use shared storage.
- Always deploy with `docker-compose -f <file>.yaml config | docker stack deploy -c - <stack>`
  because `docker stack deploy` alone does not read `.env` files.
- If nuc8-2 becomes overloaded in the future, lighter services (e.g., komga,
  lidarr) can be moved back in the same manner.
