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

## Post-Rebalance Distribution

### nuc8-1 (11 tasks)
- media: bazarr, komga, lidarr, mylar3, overseerr, readarr, recyclarr, tautulli
- tier1: adguard1
- monitoring: prometheus

### nuc8-2 (16 tasks)
- media: sonarr, prowlarr, radarr, cross-seed, epic-games, maintainerr, plex-meta-manager
- teslamate: database, grafana, mosquitto, teslamate
- monitoring: grafana, graphite_exporter
- tier1: adguard2, nginx-proxy-manager (x2)
- smarthomeserver: tesla-http-proxy

## Notes

- The NFS media volume (TrueNAS) is network-mounted and works from either node.
- Only SQLite config dirs need local disk — this is why we rsync rather than
  use shared storage.
- If nuc8-2 becomes overloaded in the future, lighter services (e.g., readarr,
  lidarr) can be moved in the same manner.
