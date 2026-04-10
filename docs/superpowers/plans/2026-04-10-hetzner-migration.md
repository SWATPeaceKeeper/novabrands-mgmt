# Hetzner CX33 Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate the novabrands-mgmt Docker stack (OpenProject, Nextcloud, Collabora, Traefik) from OVH RISE-S to Hetzner CX33 VPS with zero data loss.

**Architecture:** Stop-Copy-Start migration. Archive old OVH configs, adapt setup.sh + docker-compose.yml for Hetzner CX33 (8 GB RAM, root user, no RAID), provision server, dump and transfer data, restore on Hetzner, switch DNS.

**Tech Stack:** Docker Compose, PostgreSQL 18, Traefik v3, Cloudflare DNS API, rsync, pass-cli (Proton Pass)

**Spec:** `docs/superpowers/specs/2026-04-10-hetzner-migration-design.md`

**SSH:** `ssh -i ~/.ssh/novabrands-hetzner root@178.104.149.226`

---

## File Structure

| Action | File | Responsibility |
|--------|------|---------------|
| Create | `archive/ovh/docker-compose.yml` | Archived OVH compose stack |
| Create | `archive/ovh/setup.sh` | Archived OVH setup script |
| Create | `archive/ovh/dump-databases.sh` | Archived OVH DB dump script |
| Create | `archive/ovh/.env.template` | Archived OVH env template |
| Create | `archive/ovh/traefik/traefik.yml` | Archived OVH traefik config |
| Modify | `setup.sh` | Adapted for Hetzner CX33 (IP, user, no RAID, swap, reduced subdomains) |
| Modify | `docker-compose.yml` | Reduced stack, adjusted memory limits |
| Modify | `.env.template` | Remove Coder/Speakr variables |
| Modify | `dump-databases.sh` | Remove Coder DB dump |
| Keep | `traefik/traefik.yml` | Unchanged (TLS config is server-agnostic) |

---

### Task 1: Archive old OVH configs

**Files:**
- Create: `archive/ovh/docker-compose.yml`
- Create: `archive/ovh/setup.sh`
- Create: `archive/ovh/dump-databases.sh`
- Create: `archive/ovh/.env.template`
- Create: `archive/ovh/traefik/traefik.yml`

- [ ] **Step 1: Create archive directory and copy files**

```bash
mkdir -p archive/ovh/traefik
cp docker-compose.yml archive/ovh/docker-compose.yml
cp setup.sh archive/ovh/setup.sh
cp dump-databases.sh archive/ovh/dump-databases.sh
cp .env.template archive/ovh/.env.template
cp traefik/traefik.yml archive/ovh/traefik/traefik.yml
```

- [ ] **Step 2: Verify all files are copied**

```bash
ls -la archive/ovh/ archive/ovh/traefik/
```

Expected: all 5 files present with matching sizes.

- [ ] **Step 3: Commit**

```bash
git add archive/
git commit -m "chore: archive OVH configs before Hetzner migration"
```

---

### Task 2: Adapt docker-compose.yml for Hetzner CX33

**Files:**
- Modify: `docker-compose.yml`

- [ ] **Step 1: Remove Coder Socket Proxy service (lines 48-76)**

Remove the entire `coder-socket-proxy` service block:

```yaml
  # DOCKER SOCKET PROXY (Coder - read/write for container provisioning)
  coder-socket-proxy:
    ...
```

- [ ] **Step 2: Remove Coder services (lines 442-527)**

Remove the entire `coder-db` and `coder` service blocks.

- [ ] **Step 3: Remove Speakr services (lines 529-605)**

Remove the entire `speakr-asr` and `speakr` service blocks.

- [ ] **Step 4: Remove Coder/Speakr networks**

From the `networks:` section, remove:

```yaml
  coder-socket-proxy:
    driver: bridge
    internal: true
```

```yaml
  coder-backend:
    external: true
```

```yaml
  speakr-backend:
    driver: bridge
```

- [ ] **Step 5: Remove Coder/Speakr volumes**

From the `volumes:` section, remove:

```yaml
  coder-pgdata:
  speakr-uploads:
  speakr-instance:
  speakr-asr-cache:
```

- [ ] **Step 6: Adjust memory limits for 8 GB RAM**

Update resource limits for each remaining service:

**OpenProject** (limit 2048M → 1536M, reservation 1536M → 1024M):
```yaml
    deploy:
      resources:
        limits:
          memory: 1536M
        reservations:
          memory: 1024M
```

**OpenProject DB** (limit 512M → 384M, reservation 256M → 192M):
```yaml
    deploy:
      resources:
        limits:
          memory: 384M
        reservations:
          memory: 192M
```

**Nextcloud** (limit 1536M → 1024M, reservation 768M → 512M):
```yaml
    deploy:
      resources:
        limits:
          memory: 1024M
        reservations:
          memory: 512M
```

**Nextcloud DB** (limit 512M → 384M, reservation 256M → 192M):
```yaml
    deploy:
      resources:
        limits:
          memory: 384M
        reservations:
          memory: 192M
```

**Redis** (limit 320M → 256M):
```yaml
    deploy:
      resources:
        limits:
          memory: 256M
        reservations:
          memory: 128M
```

**Nextcloud Cron** (limit 512M → 384M):
```yaml
    deploy:
      resources:
        limits:
          memory: 384M
        reservations:
          memory: 128M
```

**Collabora** (limit 1536M → 1024M, reservation 1024M → 512M):
```yaml
    deploy:
      resources:
        limits:
          memory: 1024M
        reservations:
          memory: 512M
```

Socket Proxy, Traefik, Memcached keep their current values.

- [ ] **Step 7: Update file header comment**

Replace the header block (lines 1-18):

```yaml
# ============================================================================
# Documentation Stack - Docker Compose
# ============================================================================
# Standort: Hetzner CX33 VPS (4 vCPU, 8 GB RAM, 80 GB SSD)
# Pfad auf Server: /opt/containers/novabrands-mgmt/docker-compose.yml
#
# Services: Traefik, OpenProject, Nextcloud, Collabora
# Datenbanken: 2x PostgreSQL 18, 1x Redis 7, 1x Memcached
#
# NETZWERKE:
# - proxy:                Traefik -> oeffentliche Services
# - socket-proxy:         Traefik <-> Docker Socket Proxy (read-only)
# - openproject-backend:  OpenProject <-> PostgreSQL, Memcached
# - nextcloud-backend:    Nextcloud <-> PostgreSQL, Redis
# ============================================================================
```

- [ ] **Step 8: Verify YAML syntax**

```bash
docker compose config --quiet 2>&1 || echo "YAML syntax error"
```

Expected: no output (valid YAML). Note: this may warn about missing .env variables — that's OK at this stage.

- [ ] **Step 9: Commit**

```bash
git add docker-compose.yml
git commit -m "feat: adapt docker-compose.yml for Hetzner CX33

Remove Coder and Speakr services, reduce memory limits for 8 GB RAM.
Total limit budget: ~5.5 GB (was ~7.5 GB)."
```

---

### Task 3: Adapt .env.template for Hetzner

**Files:**
- Modify: `.env.template`

- [ ] **Step 1: Remove Coder variables**

Remove these lines:

```
CODER_HOSTNAME=coder.novabrands.org
```

```
# Coder (Config)
CODER_DB_NAME=coder
CODER_DB_USER=coder
```

```
CODER_DB_PASSWORD={{ pass://Novabrands Infra/Coder DB/password }}
HCLOUD_TOKEN={{ pass://Novabrands Infra/Hetzner Cloud/password }}
```

- [ ] **Step 2: Remove Speakr variables**

Remove these lines:

```
# Speakr (Config)
SPEAKR_HOSTNAME=ai.novabrands.org
SPEAKR_ADMIN_USER=admin
SPEAKR_ADMIN_EMAIL=admin@novabrands.org
```

```
SPEAKR_ADMIN_PASSWORD={{ pass://Novabrands Infra/Speakr Admin/password }}
SPEAKR_HF_TOKEN={{ pass://Novabrands Infra/HuggingFace/password }}
```

- [ ] **Step 3: Update header comment**

Update the Proton Pass items list to remove Coder, Speakr, HuggingFace, Hetzner Cloud:

```
# Voraussetzung: Proton Pass Vault "Novabrands Infra" mit den Items:
#   - OpenProject DB      (password)
#   - OpenProject App     (custom field: secret_key_base)
#   - Nextcloud DB        (password)
#   - Nextcloud Admin     (password)
#   - Redis               (password)
#   - Collabora Admin     (password)
#   - Traefik Dashboard   (password)
#   - SMTP                (username, password)
```

- [ ] **Step 4: Commit**

```bash
git add .env.template
git commit -m "chore: remove Coder and Speakr variables from .env.template"
```

---

### Task 4: Adapt dump-databases.sh for reduced stack

**Files:**
- Modify: `dump-databases.sh`

- [ ] **Step 1: Remove Coder DB dump section**

Remove lines 32-39 (the Coder DB dump block):

```bash
echo "=== Dumping Coder DB ==="
docker exec coder-db pg_dump \
  -U coder \
  -d coder \
  --format=custom \
  --file=/tmp/coder.dump
docker cp coder-db:/tmp/coder.dump "$DUMP_DIR/coder.dump"
docker exec coder-db rm /tmp/coder.dump
```

- [ ] **Step 2: Verify script syntax**

```bash
bash -n dump-databases.sh
```

Expected: no output (valid syntax).

- [ ] **Step 3: Commit**

```bash
git add dump-databases.sh
git commit -m "chore: remove Coder DB dump from dump-databases.sh"
```

---

### Task 5: Adapt setup.sh for Hetzner CX33

**Files:**
- Modify: `setup.sh`

- [ ] **Step 1: Update configuration block (lines 44-52)**

Replace:

```bash
SERVER_IP="51.77.84.41"
SSH_KEY_FILE="${HOME}/.ssh/novabrands-mgmt"
ADMIN_USER="ubuntu"
```

With:

```bash
SERVER_IP="178.104.149.226"
SSH_KEY_FILE="${HOME}/.ssh/novabrands-hetzner"
ADMIN_USER="root"
```

- [ ] **Step 2: Update subdomains array (line 52)**

Replace:

```bash
SUBDOMAINS=("openproject" "cloud" "office" "coder" "traefik")
```

With:

```bash
SUBDOMAINS=("openproject" "cloud" "office" "traefik")
```

- [ ] **Step 3: Update header comment (lines 1-36)**

Replace:

```bash
# Provisioniert einen OVH RISE-S Dedicated Server (Ubuntu 24.04 LTS):
```

With:

```bash
# Provisioniert einen Hetzner CX33 VPS (Ubuntu 24.04 LTS):
```

Update the prerequisites:

```bash
#   - SSH Key ~/.ssh/novabrands-hetzner vorhanden
```

Remove:

```bash
#   - OVH-Server laeuft mit Ubuntu 24.04, User 'ubuntu' mit sudo
```

Add:

```bash
#   - Hetzner VPS laeuft mit Ubuntu 24.04, Root-Zugang per SSH Key
```

- [ ] **Step 4: Replace RAID-Check (Schritt 3) with VPS-compatible check**

Replace the RAID section (lines 126-134):

```bash
# ---------------------------------------------------------------------------
# 3. RAID-HEALTH PRUEFEN
# ---------------------------------------------------------------------------
info "Pruefe RAID-Status..."

RAID_STATUS=$(remote "cat /proc/mdstat" 2>/dev/null)
if echo "$RAID_STATUS" | grep -q '\[UU\]'; then
  ok "RAID-1 healthy (alle Disks aktiv)."
else
  warn "RAID-Status nicht optimal:"
  echo "$RAID_STATUS"
  die "RAID ist nicht healthy. Server nicht provisionieren bis RAID repariert."
fi
```

With:

```bash
# ---------------------------------------------------------------------------
# 3. DISK-HEALTH PRUEFEN
# ---------------------------------------------------------------------------
info "Pruefe Disk-Status..."

DISK_USAGE=$(remote "df -h / | tail -1 | awk '{print \$5}' | tr -d '%'")
if [ "$DISK_USAGE" -lt 90 ]; then
  ok "Disk OK (${DISK_USAGE}% belegt)."
else
  die "Disk fast voll (${DISK_USAGE}%). Platz schaffen bevor Setup fortfaehrt."
fi
```

- [ ] **Step 5: Adapt remote() function for root user**

Since `ADMIN_USER="root"`, the `sudo` calls in remote commands are unnecessary but harmless. No change needed — `sudo` as root is a no-op.

However, update the SSH-Hardening section (lines 166-184) to allow root login via key (the default AllowUsers was `ubuntu`):

Replace:

```bash
AllowUsers ubuntu
```

With:

```bash
AllowUsers root
```

- [ ] **Step 6: Update Swappiness comment and add Swap-File step**

In the System-Tuning section (lines 316-332), replace:

```bash
  # Swappiness runter (64 GB RAM, Swap nur als Notfall)
```

With:

```bash
  # Swappiness runter (8 GB RAM, Swap als Sicherheitsnetz)
```

Add a new section after System-Tuning (after step 11, before fail2ban):

```bash
# ---------------------------------------------------------------------------
# 11b. SWAP-FILE ANLEGEN
# ---------------------------------------------------------------------------
info "Lege 2 GB Swap-File an..."

remote "
  if [ ! -f /swapfile ]; then
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile swap swap defaults 0 0' >> /etc/fstab
    echo 'Swap-File angelegt und aktiviert.'
  else
    echo 'Swap-File existiert bereits.'
  fi
"
ok "Swap-File aktiv (2 GB)."
```

- [ ] **Step 7: Remove coder-backend network creation**

In the Docker-Netzwerke section (lines 416-425), remove:

```bash
  sudo docker network create coder-backend 2>/dev/null || true
```

- [ ] **Step 8: Update summary output (lines 534-578)**

Replace the summary section to reflect Hetzner CX33:

```bash
echo "============================================================================"
echo "  DOCUMENTATION STACK - SERVER SETUP ABGESCHLOSSEN"
echo "============================================================================"
echo ""
echo "  Server:     ${SERVER_IP} (novabrands-mgmt)"
echo "  SSH:        ssh -i ${SSH_KEY_FILE} ${ADMIN_USER}@${SERVER_IP}"
echo "  User:       ${ADMIN_USER}"
echo "  Domain:     ${DOMAIN}"
echo "  Typ:        Hetzner CX33 VPS (4 vCPU, 8 GB RAM, 80 GB SSD)"
echo "  OS:         Ubuntu 24.04 LTS"
echo ""
echo "  Sicherheit:"
echo "    UFW:            aktiv (SSH, HTTP, HTTPS)"
echo "    fail2ban:       aktiv (SSH: 3 Versuche, 1h Ban)"
echo "    SSH:            Key-only, ClientAlive=300s"
echo "    Kernel:         Spoofing/Redirect/SYN-Flood-Schutz, ASLR, no Core Dumps"
echo "    /dev/shm:       noexec, nosuid, nodev"
echo "    Docker:         live-restore, no-new-privileges, Socket Proxy"
echo "    Swappiness:     10"
echo "    Swap:           2 GB (/swapfile)"
echo "    Services:       ModemManager, multipathd, udisks2 deaktiviert"
echo ""
echo "  DNS Records:"
for sub in "${SUBDOMAINS[@]}"; do
  printf "    %-16s https://%s.%s\n" "${sub}:" "${sub}" "${DOMAIN}"
done
echo ""
echo "  Traefik Dashboard:"
echo "    URL:       https://traefik.${DOMAIN}"
echo "    User:      admin"
echo "    Passwort:  ${TRAEFIK_PASSWORD}"
echo ""
echo "  Naechste Schritte:"
echo "    1. SMTP-Daten in .env eintragen"
echo "    2. Documentation Stack starten:"
echo "       ssh -i ${SSH_KEY_FILE} ${ADMIN_USER}@${SERVER_IP}"
echo "       cd ${DEPLOY_DIR} && docker compose up -d"
echo "    3. Services konfigurieren (siehe SPEC.md)"
echo ""
echo "  WICHTIG: Traefik-Passwort JETZT notieren — wird nicht erneut angezeigt."
echo ""
echo "============================================================================"
```

- [ ] **Step 9: Verify script syntax**

```bash
bash -n setup.sh
```

Expected: no output (valid syntax).

- [ ] **Step 10: Commit**

```bash
git add setup.sh
git commit -m "feat: adapt setup.sh for Hetzner CX33 VPS

Replace OVH RISE-S specifics: new IP (178.104.149.226), root user,
disk check instead of RAID, 2 GB swap file, reduced subdomains."
```

---

### Task 6: Provision Hetzner server

**Files:** None (remote execution of setup.sh)

**Prerequisites:**
- `pass-cli` logged in (`pass-cli login`)
- `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ZONE_ID` exported
- SSH key `~/.ssh/novabrands-hetzner` in place
- Public key authorized on Hetzner server

- [ ] **Step 1: Verify prerequisites**

```bash
pass-cli vault list
echo "CF_TOKEN set: ${CLOUDFLARE_API_TOKEN:+yes}"
echo "CF_ZONE set: ${CLOUDFLARE_ZONE_ID:+yes}"
ssh -i ~/.ssh/novabrands-hetzner -o ConnectTimeout=5 root@178.104.149.226 "echo OK"
```

Expected: vault list shows "Novabrands Infra", both env vars set, SSH returns "OK".

- [ ] **Step 2: Run setup.sh**

```bash
cd /home/coder/repos/novabrands-mgmt
./setup.sh
```

Expected: all steps complete with `[OK]`, summary printed at end.

- [ ] **Step 3: Verify server state**

```bash
ssh -i ~/.ssh/novabrands-hetzner root@178.104.149.226 "
  echo '=== Docker ===' && docker --version
  echo '=== UFW ===' && ufw status | head -5
  echo '=== fail2ban ===' && systemctl is-active fail2ban
  echo '=== Swap ===' && swapon --show
  echo '=== Traefik ===' && docker ps --filter name=traefik --format '{{.Status}}'
  echo '=== Networks ===' && docker network ls --format '{{.Name}}' | grep -E 'proxy|backend'
"
```

Expected: Docker installed, UFW active, fail2ban active, 2G swap, Traefik running, networks created.

- [ ] **Step 4: Verify .env exists on server**

```bash
ssh -i ~/.ssh/novabrands-hetzner root@178.104.149.226 "
  [ -f /opt/containers/novabrands-mgmt/.env ] && echo '.env exists' || echo '.env MISSING'
  stat -c '%a' /opt/containers/novabrands-mgmt/.env
"
```

Expected: `.env exists`, permissions `600`.

---

### Task 7: Migrate data from OVH to Hetzner

**Files:** None (remote execution)

**OVH SSH:** `ssh -i ~/.ssh/novabrands-mgmt ubuntu@51.77.84.41`
**Hetzner SSH:** `ssh -i ~/.ssh/novabrands-hetzner root@178.104.149.226`

- [ ] **Step 1: Activate Nextcloud maintenance mode on OVH**

```bash
ssh -i ~/.ssh/novabrands-mgmt ubuntu@51.77.84.41 "
  docker exec -u www-data nextcloud php occ maintenance:mode --on
"
```

Expected: `Maintenance mode enabled`

- [ ] **Step 2: Dump databases on OVH**

```bash
ssh -i ~/.ssh/novabrands-mgmt ubuntu@51.77.84.41 "
  mkdir -p /opt/containers/novabrands-mgmt/db-dumps

  echo '=== Dumping OpenProject DB ==='
  docker exec openproject-db pg_dump \
    -U openproject -d openproject \
    --format=custom --file=/tmp/openproject.dump
  docker cp openproject-db:/tmp/openproject.dump /opt/containers/novabrands-mgmt/db-dumps/
  docker exec openproject-db rm /tmp/openproject.dump

  echo '=== Dumping Nextcloud DB ==='
  docker exec nextcloud-db pg_dump \
    -U nextcloud -d nextcloud \
    --format=custom --file=/tmp/nextcloud.dump
  docker cp nextcloud-db:/tmp/nextcloud.dump /opt/containers/novabrands-mgmt/db-dumps/
  docker exec nextcloud-db rm /tmp/nextcloud.dump

  ls -lh /opt/containers/novabrands-mgmt/db-dumps/
"
```

Expected: two dump files (`openproject.dump` ~88 MB, `nextcloud.dump` ~77 MB).

- [ ] **Step 3: Stop all services on OVH**

```bash
ssh -i ~/.ssh/novabrands-mgmt ubuntu@51.77.84.41 "
  cd /opt/containers/novabrands-mgmt && docker compose down
"
```

Expected: all containers stopped and removed. Volumes persist.

- [ ] **Step 4: Export volume data on OVH**

```bash
ssh -i ~/.ssh/novabrands-mgmt ubuntu@51.77.84.41 "
  mkdir -p /opt/containers/novabrands-mgmt/export

  echo '=== Exporting nc-html ==='
  docker run --rm \
    -v novabrands-mgmt_nc-html:/data:ro \
    -v /opt/containers/novabrands-mgmt/export:/export \
    alpine tar czf /export/nc-html.tar.gz -C /data .

  echo '=== Exporting nc-data ==='
  docker run --rm \
    -v novabrands-mgmt_nc-data:/data:ro \
    -v /opt/containers/novabrands-mgmt/export:/export \
    alpine tar czf /export/nc-data.tar.gz -C /data .

  echo '=== Exporting op-assets ==='
  docker run --rm \
    -v novabrands-mgmt_op-assets:/data:ro \
    -v /opt/containers/novabrands-mgmt/export:/export \
    alpine tar czf /export/op-assets.tar.gz -C /data .

  ls -lh /opt/containers/novabrands-mgmt/export/
"
```

Expected: three tar.gz files totaling ~1 GB.

- [ ] **Step 5: Transfer data OVH → Hetzner**

Run from a machine that can reach both servers (this workspace, or OVH directly):

```bash
ssh -i ~/.ssh/novabrands-hetzner root@178.104.149.226 "mkdir -p /opt/containers/novabrands-mgmt/migration"

# Transfer DB dumps
scp -i ~/.ssh/novabrands-mgmt ubuntu@51.77.84.41:/opt/containers/novabrands-mgmt/db-dumps/*.dump /tmp/
scp -i ~/.ssh/novabrands-hetzner /tmp/*.dump root@178.104.149.226:/opt/containers/novabrands-mgmt/migration/

# Transfer volume exports
scp -i ~/.ssh/novabrands-mgmt ubuntu@51.77.84.41:/opt/containers/novabrands-mgmt/export/*.tar.gz /tmp/
scp -i ~/.ssh/novabrands-hetzner /tmp/*.tar.gz root@178.104.149.226:/opt/containers/novabrands-mgmt/migration/

# Verify
ssh -i ~/.ssh/novabrands-hetzner root@178.104.149.226 "ls -lh /opt/containers/novabrands-mgmt/migration/"
```

Expected: 5 files on Hetzner (2 dumps + 3 tar.gz).

Alternative (direct OVH → Hetzner if SSH is set up between them):

```bash
ssh -i ~/.ssh/novabrands-mgmt ubuntu@51.77.84.41 "
  rsync -avz \
    /opt/containers/novabrands-mgmt/db-dumps/ \
    /opt/containers/novabrands-mgmt/export/ \
    root@178.104.149.226:/opt/containers/novabrands-mgmt/migration/
"
```

---

### Task 8: Restore data and start services on Hetzner

**Files:** None (remote execution)

- [ ] **Step 1: Start database containers only**

```bash
ssh -i ~/.ssh/novabrands-hetzner root@178.104.149.226 "
  cd /opt/containers/novabrands-mgmt
  docker compose up -d openproject-db nextcloud-db
  sleep 10
  docker ps --filter 'name=-db' --format '{{.Names}}: {{.Status}}'
"
```

Expected: both DB containers running and healthy.

- [ ] **Step 2: Restore OpenProject database**

```bash
ssh -i ~/.ssh/novabrands-hetzner root@178.104.149.226 "
  docker cp /opt/containers/novabrands-mgmt/migration/openproject.dump openproject-db:/tmp/
  docker exec openproject-db pg_restore \
    -U openproject -d openproject \
    --clean --if-exists \
    /tmp/openproject.dump
  docker exec openproject-db rm /tmp/openproject.dump
  echo 'OpenProject DB restored'
"
```

Expected: restore completes (some warnings about non-existing objects are OK with `--clean --if-exists`).

- [ ] **Step 3: Restore Nextcloud database**

```bash
ssh -i ~/.ssh/novabrands-hetzner root@178.104.149.226 "
  docker cp /opt/containers/novabrands-mgmt/migration/nextcloud.dump nextcloud-db:/tmp/
  docker exec nextcloud-db pg_restore \
    -U nextcloud -d nextcloud \
    --clean --if-exists \
    /tmp/nextcloud.dump
  docker exec nextcloud-db rm /tmp/nextcloud.dump
  echo 'Nextcloud DB restored'
"
```

Expected: restore completes.

- [ ] **Step 4: Import Nextcloud volume data**

```bash
ssh -i ~/.ssh/novabrands-hetzner root@178.104.149.226 "
  cd /opt/containers/novabrands-mgmt

  echo '=== Importing nc-html ==='
  docker run --rm \
    -v novabrands-mgmt_nc-html:/data \
    -v $(pwd)/migration:/import:ro \
    alpine sh -c 'tar xzf /import/nc-html.tar.gz -C /data'

  echo '=== Importing nc-data ==='
  docker run --rm \
    -v novabrands-mgmt_nc-data:/data \
    -v $(pwd)/migration:/import:ro \
    alpine sh -c 'tar xzf /import/nc-data.tar.gz -C /data'

  echo '=== Importing op-assets ==='
  docker run --rm \
    -v novabrands-mgmt_op-assets:/data \
    -v $(pwd)/migration:/import:ro \
    alpine sh -c 'tar xzf /import/op-assets.tar.gz -C /data'

  echo 'Volume data imported'
"
```

Expected: all three imports complete without error.

- [ ] **Step 5: Start all services**

```bash
ssh -i ~/.ssh/novabrands-hetzner root@178.104.149.226 "
  cd /opt/containers/novabrands-mgmt
  docker compose up -d
  sleep 30
  docker ps --format 'table {{.Names}}\t{{.Status}}'
"
```

Expected: all containers running (traefik, socket-proxy, openproject, openproject-db, openproject-cache, nextcloud, nextcloud-db, nextcloud-redis, nextcloud-cron, collabora).

- [ ] **Step 6: Check healthchecks**

```bash
ssh -i ~/.ssh/novabrands-hetzner root@178.104.149.226 "
  echo '=== Health ===' 
  docker inspect --format='{{.Name}}: {{.State.Health.Status}}' \
    openproject openproject-db nextcloud nextcloud-db nextcloud-redis nextcloud-cron 2>/dev/null
  echo '=== Logs (errors only) ==='
  docker logs openproject 2>&1 | tail -5
  docker logs nextcloud 2>&1 | tail -5
"
```

Expected: all services `healthy`. No critical errors in logs.

- [ ] **Step 7: Disable Nextcloud maintenance mode**

```bash
ssh -i ~/.ssh/novabrands-hetzner root@178.104.149.226 "
  docker exec -u www-data nextcloud php occ maintenance:mode --off
"
```

Expected: `Maintenance mode disabled`

---

### Task 9: DNS switch and smoke test

**Files:** None (Cloudflare API + manual testing)

- [ ] **Step 1: Update DNS records to Hetzner IP**

Option A — via setup.sh DNS section (if CLOUDFLARE_API_TOKEN and CLOUDFLARE_ZONE_ID are set):

```bash
export CLOUDFLARE_API_TOKEN=...
export CLOUDFLARE_ZONE_ID=...

for sub in openproject cloud office traefik; do
  FQDN="${sub}.novabrands.org"
  RECORD_ID=$(curl -s -X GET \
    "https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID}/dns_records?type=A&name=${FQDN}" \
    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" | jq -r '.result[0].id')

  curl -s -X PUT \
    "https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID}/dns_records/${RECORD_ID}" \
    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"type\":\"A\",\"name\":\"${sub}\",\"content\":\"178.104.149.226\",\"ttl\":300,\"proxied\":false}" | jq '.success'

  echo "${FQDN} -> 178.104.149.226"
done
```

Option B — manually in Cloudflare Dashboard.

Expected: all A records point to `178.104.149.226`.

- [ ] **Step 2: Wait for DNS propagation**

```bash
for sub in openproject cloud office traefik; do
  echo -n "${sub}.novabrands.org -> "
  dig +short "${sub}.novabrands.org" A
done
```

Expected: all resolve to `178.104.149.226`. May take up to 5 minutes (TTL 300s).

- [ ] **Step 3: Wait for Let's Encrypt certificates**

Traefik automatically requests new certificates. Check:

```bash
ssh -i ~/.ssh/novabrands-hetzner root@178.104.149.226 "
  docker logs traefik 2>&1 | grep -i 'certificate\|acme' | tail -10
"
```

Expected: certificate obtained messages for each domain.

- [ ] **Step 4: Smoke test — OpenProject**

Open `https://openproject.novabrands.org` in browser:
- [ ] Login page loads
- [ ] Login with existing credentials works
- [ ] Can open an existing project
- [ ] Can view work packages

- [ ] **Step 5: Smoke test — Nextcloud**

Open `https://cloud.novabrands.org` in browser:
- [ ] Login page loads
- [ ] Login with existing credentials works
- [ ] Files are present
- [ ] Can upload a test file

- [ ] **Step 6: Smoke test — Collabora**

In Nextcloud:
- [ ] Open a .docx or .odt file
- [ ] Collabora editor loads
- [ ] Can type and save

- [ ] **Step 7: Smoke test — Traefik Dashboard**

Open `https://traefik.novabrands.org`:
- [ ] Basic auth prompt appears
- [ ] Dashboard loads after login
- [ ] All routers show green

---

### Task 10: Cleanup

- [ ] **Step 1: Verify stability (wait 24-48h)**

Check periodically:

```bash
ssh -i ~/.ssh/novabrands-hetzner root@178.104.149.226 "
  docker ps --format 'table {{.Names}}\t{{.Status}}'
  echo '=== Memory ==='
  free -h
  echo '=== Disk ==='
  df -h /
"
```

Expected: all services running, memory and disk within bounds.

- [ ] **Step 2: Remove migration data on Hetzner**

```bash
ssh -i ~/.ssh/novabrands-hetzner root@178.104.149.226 "
  rm -rf /opt/containers/novabrands-mgmt/migration
  echo 'Migration data removed'
"
```

- [ ] **Step 3: Update CLAUDE.md**

Update the Infrastructure Overview section in `CLAUDE.md` to reflect the new server details (Hetzner CX33, new IP, reduced service list).

- [ ] **Step 4: Commit CLAUDE.md update**

```bash
git add CLAUDE.md
git commit -m "docs: update infrastructure overview for Hetzner CX33"
```

- [ ] **Step 5: Decide on OVH server**

When satisfied (3-5 days stable):
- Cancel OVH RISE-S contract
- Remove `~/.ssh/novabrands-mgmt` key (optional, keep if other OVH services)
- Remove old DNS records for `coder.novabrands.org` and `ai.novabrands.org`
