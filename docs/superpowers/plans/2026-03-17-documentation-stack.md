# Documentation Stack Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy a production-ready Docker Compose stack with OpenProject, Nextcloud (S3 objectstore), Collabora, and Coder on a Hetzner server behind Traefik v3.

**Architecture:** 10 containers across 4 isolated backend networks, fronted by an existing Traefik v3 reverse proxy. Nextcloud files go to Hetzner Object Storage (S3). Coder provisions workspaces on external Hetzner Cloud VMs. Borgmatic backs up to Hetzner StorageBox.

**Tech Stack:** Docker Compose, PostgreSQL 16, Redis 7, Memcached 1.6, Traefik v3, Borgmatic/BorgBackup, Hetzner Object Storage (S3)

**Spec:** `SPEC.md` (v2.2) — the single source of truth for all configuration values, environment variables, and architecture decisions.

---

## File Structure

| Action | Path | Responsibility |
|--------|------|---------------|
| Rewrite | `docker-compose.yml` | Complete stack definition (10 containers, 4 networks, 6 volumes) |
| Rewrite | `secrets.env.example` | Template with all environment variables and generation hints |
| Create | `.gitignore` | Exclude secrets.env, logs, db-dumps |
| Create | `dump-databases.sh` | Backup script: dumps all 3 PostgreSQL databases |
| Keep | `SPEC.md` | Specification (already written, do not modify) |
| Remove | `HETZNER_STACK_OPENPROJECT_NEXTCLOUD_V1.md` | Replaced by SPEC.md |

**Not created in this plan (post-deployment / separate repos):**
- Borgmatic config (lives in `/etc/borgmatic/config.yaml` on the server, not in this repo)
- Coder Terraform templates (managed inside Coder UI, reference: `ntimo/coder-hetzner-cloud-template`)

---

## Task 1: Repository Housekeeping

**Files:**
- Create: `.gitignore`
- Remove: `HETZNER_STACK_OPENPROJECT_NEXTCLOUD_V1.md`

- [ ] **Step 1: Create `.gitignore`**

```
secrets.env
*.log
db-dumps/
```

- [ ] **Step 2: Remove obsolete V1 document**

```bash
git rm HETZNER_STACK_OPENPROJECT_NEXTCLOUD_V1.md
```

The V1 concept is fully superseded by `SPEC.md`.

- [ ] **Step 3: Commit**

```bash
git add .gitignore
git commit -m "chore: add .gitignore, remove obsolete V1 concept"
```

---

## Task 2: secrets.env.example

**Files:**
- Rewrite: `secrets.env.example`

All environment variables from SPEC.md Section 7. This file is the template — users copy it to `secrets.env` and fill in values.

- [ ] **Step 1: Write `secrets.env.example`**

```bash
# =============================================================================
# secrets.env — Documentation Stack (OpenProject + Nextcloud + Collabora + Coder)
# =============================================================================
# Kopiere diese Datei:  cp secrets.env.example secrets.env
# Dann alle Werte ausfuellen und secrets.env NIEMALS in Git committen!
# =============================================================================

# ---------------------------------------------------------------------------
# Domains
# ---------------------------------------------------------------------------
OP_HOSTNAME=openproject.example.de
NC_HOSTNAME=cloud.example.de
COLLABORA_HOSTNAME=office.example.de
CODER_HOSTNAME=coder.example.de

# ---------------------------------------------------------------------------
# OpenProject
# ---------------------------------------------------------------------------
OP_DB_NAME=openproject
OP_DB_USER=openproject
OP_DB_PASSWORD=           # openssl rand -base64 32
OP_SECRET_KEY_BASE=       # openssl rand -hex 64
OP_RAILS_MIN_THREADS=4
OP_RAILS_MAX_THREADS=16

# ---------------------------------------------------------------------------
# Nextcloud
# ---------------------------------------------------------------------------
NC_DB_NAME=nextcloud
NC_DB_USER=nextcloud
NC_DB_PASSWORD=           # openssl rand -base64 32
NC_REDIS_PASSWORD=        # openssl rand -base64 32
NC_ADMIN_USER=admin
NC_ADMIN_PASSWORD=        # Sicheres Admin-Passwort waehlen

# ---------------------------------------------------------------------------
# Hetzner Object Storage (S3)
# ---------------------------------------------------------------------------
S3_BUCKET=                # Bucket-Name aus Hetzner Cloud Console
S3_HOSTNAME=fsn1.your-objectstorage.com   # Region-Endpoint (OHNE Bucket-Prefix!)
S3_KEY=                   # Access Key
S3_SECRET=                # Secret Key
S3_REGION=fsn1
S3_PORT=443

# ---------------------------------------------------------------------------
# Coder
# ---------------------------------------------------------------------------
CODER_DB_NAME=coder
CODER_DB_USER=coder
CODER_DB_PASSWORD=        # openssl rand -base64 32
HCLOUD_TOKEN=             # Hetzner Cloud API Token (Read/Write)

# ---------------------------------------------------------------------------
# Collabora
# ---------------------------------------------------------------------------
# COLLABORA_DOMAIN nicht noetig — aliasgroup1 nutzt NC_HOSTNAME direkt
COLLABORA_ADMIN_USER=admin
COLLABORA_ADMIN_PASSWORD=    # openssl rand -base64 16

# ---------------------------------------------------------------------------
# SMTP (Proton oder SMTP2Go)
# ---------------------------------------------------------------------------
SMTP_HOST=smtp.example.de
SMTP_PORT=587
SMTP_USER=noreply@example.de
SMTP_PASSWORD=
SMTP_FROM=noreply@example.de
SMTP_DOMAIN=example.de
```

- [ ] **Step 2: Commit**

```bash
git add secrets.env.example
git commit -m "feat: rewrite secrets.env.example for full stack (OP+NC+Collabora+Coder)"
```

---

## Task 3: docker-compose.yml — Networks, Volumes, OpenProject Stack

**Files:**
- Rewrite: `docker-compose.yml` (partial — OpenProject portion)

Reference: SPEC.md Sections 2, 3, 8 (Traefik), 13 (Resource Limits)

- [ ] **Step 1: Write docker-compose.yml header, networks, volumes, and OpenProject stack**

```yaml
# =============================================================================
# Documentation Stack — OpenProject + Nextcloud + Collabora + Coder
# =============================================================================
# Voraussetzung: Traefik v3 laeuft bereits im Netzwerk "proxy"
# Secrets:       secrets.env (siehe secrets.env.example)
# Spec:          SPEC.md v2.2
# =============================================================================

networks:
  proxy:
    external: true
  openproject-backend:
    driver: bridge
  nextcloud-backend:
    driver: bridge
  coder-backend:
    driver: bridge

volumes:
  op-pgdata:
  op-assets:
  nc-pgdata:
  nc-html:
  nc-redis:
  coder-pgdata:

services:

  # ===========================================================================
  # OpenProject 17
  # ===========================================================================

  openproject-db:
    image: postgres:16-alpine
    container_name: openproject-db
    restart: unless-stopped
    env_file: secrets.env
    environment:
      POSTGRES_DB: ${OP_DB_NAME:-openproject}
      POSTGRES_USER: ${OP_DB_USER:-openproject}
      POSTGRES_PASSWORD: ${OP_DB_PASSWORD:?OP_DB_PASSWORD muss gesetzt sein}
    volumes:
      - op-pgdata:/var/lib/postgresql/data
    networks:
      - openproject-backend
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${OP_DB_USER:-openproject} -d ${OP_DB_NAME:-openproject}"]
      interval: 15s
      timeout: 5s
      retries: 5
    deploy:
      resources:
        limits:
          memory: 512M
        reservations:
          memory: 256M

  openproject-cache:
    image: memcached:1-alpine
    container_name: openproject-cache
    restart: unless-stopped
    command: memcached -m 128
    networks:
      - openproject-backend
    healthcheck:
      test: ["CMD-SHELL", "echo stats | nc localhost 11211 | grep -q pid"]
      interval: 30s
      timeout: 5s
      retries: 3
    deploy:
      resources:
        limits:
          memory: 192M
        reservations:
          memory: 128M

  openproject:
    image: openproject/openproject:17.1.2
    container_name: openproject
    restart: unless-stopped
    env_file: secrets.env
    environment:
      OPENPROJECT_HTTPS: "true"
      OPENPROJECT_HSTS: "true"
      OPENPROJECT_HOST__NAME: ${OP_HOSTNAME:-openproject.example.de}
      OPENPROJECT_DEFAULT__LANGUAGE: de
      DATABASE_URL: "postgres://${OP_DB_USER:-openproject}:${OP_DB_PASSWORD}@openproject-db/${OP_DB_NAME:-openproject}?pool=20&encoding=unicode&reconnect=true"
      OPENPROJECT_CACHE__MEMCACHE__SERVER: "openproject-cache:11211"
      OPENPROJECT_RAILS__CACHE__STORE: "memcache"
      SECRET_KEY_BASE: ${OP_SECRET_KEY_BASE:?OP_SECRET_KEY_BASE muss gesetzt sein}
      RAILS_MIN_THREADS: ${OP_RAILS_MIN_THREADS:-4}
      RAILS_MAX_THREADS: ${OP_RAILS_MAX_THREADS:-16}
      # SMTP (auskommentieren wenn konfiguriert)
      # EMAIL_DELIVERY_METHOD: smtp
      # SMTP_ADDRESS: ${SMTP_HOST}
      # SMTP_PORT: ${SMTP_PORT:-587}
      # SMTP_DOMAIN: ${OP_HOSTNAME:-openproject.example.de}
      # SMTP_AUTHENTICATION: plain
      # SMTP_USER_NAME: ${SMTP_USER}
      # SMTP_PASSWORD: ${SMTP_PASSWORD}
      # SMTP_ENABLE_STARTTLS_AUTO: "true"
    volumes:
      - op-assets:/var/openproject/assets
    networks:
      - proxy
      - openproject-backend
    depends_on:
      openproject-db:
        condition: service_healthy
      openproject-cache:
        condition: service_started
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=proxy"
      # Router
      - "traefik.http.routers.openproject.rule=Host(`${OP_HOSTNAME}`)"
      - "traefik.http.routers.openproject.entrypoints=websecure"
      - "traefik.http.routers.openproject.tls.certresolver=letsencrypt"
      # Service
      - "traefik.http.services.openproject.loadbalancer.server.port=8080"
      # Middlewares
      - "traefik.http.routers.openproject.middlewares=op-headers,rate-limit"
      - "traefik.http.middlewares.op-headers.headers.customRequestHeaders.X-Forwarded-Proto=https"
      - "traefik.http.middlewares.op-headers.headers.stsSeconds=31536000"
      - "traefik.http.middlewares.op-headers.headers.stsIncludeSubdomains=true"
      # Rate-Limit (global — von OP- und NC-Routern referenziert)
      - "traefik.http.middlewares.rate-limit.ratelimit.average=100"
      - "traefik.http.middlewares.rate-limit.ratelimit.burst=200"
      - "traefik.http.middlewares.rate-limit.ratelimit.period=1m"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health_checks/default"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 120s
    deploy:
      resources:
        limits:
          memory: 2048M
        reservations:
          memory: 1536M
```

- [ ] **Step 2: Validate partial compose file**

```bash
docker compose config --quiet
```

Expected: no output (valid syntax). If errors about missing secrets.env, create a dummy:
```bash
cp secrets.env.example secrets.env
# Fill required vars with dummy values for validation
```

- [ ] **Step 3: Commit**

```bash
git add docker-compose.yml
git commit -m "feat: docker-compose.yml with networks, volumes, OpenProject stack"
```

---

## Task 4: docker-compose.yml — Nextcloud Stack (with S3 Objectstore)

**Files:**
- Modify: `docker-compose.yml` (append Nextcloud services)

Reference: SPEC.md Sections 3, 8, 10 (S3), 13

- [ ] **Step 1: Add Nextcloud services to docker-compose.yml**

Append after the OpenProject section:

```yaml
  # ===========================================================================
  # Nextcloud 32
  # ===========================================================================

  nextcloud-db:
    image: postgres:16-alpine
    container_name: nextcloud-db
    restart: unless-stopped
    env_file: secrets.env
    environment:
      POSTGRES_DB: ${NC_DB_NAME:-nextcloud}
      POSTGRES_USER: ${NC_DB_USER:-nextcloud}
      POSTGRES_PASSWORD: ${NC_DB_PASSWORD:?NC_DB_PASSWORD muss gesetzt sein}
    volumes:
      - nc-pgdata:/var/lib/postgresql/data
    networks:
      - nextcloud-backend
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${NC_DB_USER:-nextcloud} -d ${NC_DB_NAME:-nextcloud}"]
      interval: 15s
      timeout: 5s
      retries: 5
    deploy:
      resources:
        limits:
          memory: 512M
        reservations:
          memory: 256M

  nextcloud-redis:
    image: redis:7-alpine
    container_name: nextcloud-redis
    restart: unless-stopped
    env_file: secrets.env
    command: >
      redis-server
        --requirepass ${NC_REDIS_PASSWORD:?NC_REDIS_PASSWORD muss gesetzt sein}
        --appendonly yes
        --maxmemory 256mb
        --maxmemory-policy allkeys-lru
    volumes:
      - nc-redis:/data
    networks:
      - nextcloud-backend
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${NC_REDIS_PASSWORD}", "ping"]
      interval: 15s
      timeout: 5s
      retries: 5
    deploy:
      resources:
        limits:
          memory: 320M
        reservations:
          memory: 128M

  nextcloud:
    image: nextcloud:32.0.6-apache
    container_name: nextcloud
    restart: unless-stopped
    env_file: secrets.env
    environment:
      # Datenbank
      POSTGRES_HOST: nextcloud-db
      POSTGRES_DB: ${NC_DB_NAME:-nextcloud}
      POSTGRES_USER: ${NC_DB_USER:-nextcloud}
      POSTGRES_PASSWORD: ${NC_DB_PASSWORD}
      # Redis
      REDIS_HOST: nextcloud-redis
      REDIS_HOST_PASSWORD: ${NC_REDIS_PASSWORD}
      REDIS_HOST_PORT: 6379
      # Nextcloud
      NEXTCLOUD_ADMIN_USER: ${NC_ADMIN_USER:-admin}
      NEXTCLOUD_ADMIN_PASSWORD: ${NC_ADMIN_PASSWORD:?NC_ADMIN_PASSWORD muss gesetzt sein}
      NEXTCLOUD_TRUSTED_DOMAINS: ${NC_HOSTNAME:-cloud.example.de}
      OVERWRITEPROTOCOL: https
      OVERWRITECLIURL: "https://${NC_HOSTNAME:-cloud.example.de}"
      TRUSTED_PROXIES: "172.16.0.0/12 10.0.0.0/8 192.168.0.0/16"
      APACHE_DISABLE_REWRITE_IP: 1
      # PHP Tuning
      PHP_MEMORY_LIMIT: 1024M
      PHP_UPLOAD_LIMIT: 16G
      # S3 Primary Objectstore (built-in support)
      OBJECTSTORE_S3_BUCKET: ${S3_BUCKET}
      OBJECTSTORE_S3_REGION: ${S3_REGION:-fsn1}
      OBJECTSTORE_S3_HOST: ${S3_HOSTNAME}
      OBJECTSTORE_S3_PORT: ${S3_PORT:-443}
      OBJECTSTORE_S3_KEY: ${S3_KEY}
      OBJECTSTORE_S3_SECRET: ${S3_SECRET}
      OBJECTSTORE_S3_USEPATH_STYLE: "true"
      OBJECTSTORE_S3_AUTOCREATE: "true"
      OBJECTSTORE_S3_SSL: "true"
      # SMTP (auskommentieren wenn konfiguriert)
      # SMTP_HOST: ${SMTP_HOST}
      # SMTP_SECURE: tls
      # SMTP_PORT: ${SMTP_PORT:-587}
      # SMTP_AUTHTYPE: LOGIN
      # SMTP_NAME: ${SMTP_USER}
      # SMTP_PASSWORD: ${SMTP_PASSWORD}
      # MAIL_FROM_ADDRESS: noreply
      # MAIL_DOMAIN: ${NC_HOSTNAME:-cloud.example.de}
    volumes:
      - nc-html:/var/www/html
    networks:
      - proxy
      - nextcloud-backend
    depends_on:
      nextcloud-db:
        condition: service_healthy
      nextcloud-redis:
        condition: service_healthy
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=proxy"
      # Router
      - "traefik.http.routers.nextcloud.rule=Host(`${NC_HOSTNAME}`)"
      - "traefik.http.routers.nextcloud.entrypoints=websecure"
      - "traefik.http.routers.nextcloud.tls.certresolver=letsencrypt"
      # Service
      - "traefik.http.services.nextcloud.loadbalancer.server.port=80"
      # Middlewares
      - "traefik.http.routers.nextcloud.middlewares=nc-chain,rate-limit"
      # CalDAV/CardDAV Redirects
      - "traefik.http.middlewares.nc-redirectregex.redirectregex.permanent=true"
      - "traefik.http.middlewares.nc-redirectregex.redirectregex.regex=https://(.*)/.well-known/(?:card|cal)dav"
      - "traefik.http.middlewares.nc-redirectregex.redirectregex.replacement=https://$${1}/remote.php/dav"
      # Security Headers
      - "traefik.http.middlewares.nc-headers.headers.stsSeconds=31536000"
      - "traefik.http.middlewares.nc-headers.headers.stsIncludeSubdomains=true"
      - "traefik.http.middlewares.nc-headers.headers.stsPreload=true"
      - "traefik.http.middlewares.nc-headers.headers.customRequestHeaders.X-Forwarded-Proto=https"
      # Chain
      - "traefik.http.middlewares.nc-chain.chain.middlewares=nc-redirectregex,nc-headers"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost/status.php"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 120s
    deploy:
      resources:
        limits:
          memory: 1536M
        reservations:
          memory: 768M

  nextcloud-cron:
    image: nextcloud:32.0.6-apache
    container_name: nextcloud-cron
    restart: unless-stopped
    entrypoint: /cron.sh
    env_file: secrets.env
    environment:
      POSTGRES_HOST: nextcloud-db
      POSTGRES_DB: ${NC_DB_NAME:-nextcloud}
      POSTGRES_USER: ${NC_DB_USER:-nextcloud}
      POSTGRES_PASSWORD: ${NC_DB_PASSWORD}
      REDIS_HOST: nextcloud-redis
      REDIS_HOST_PASSWORD: ${NC_REDIS_PASSWORD}
    volumes:
      - nc-html:/var/www/html
    networks:
      - nextcloud-backend
    depends_on:
      nextcloud:
        condition: service_healthy
    deploy:
      resources:
        limits:
          memory: 512M
        reservations:
          memory: 128M
```

**Wichtig:** Kein `nc-data` Volume — Dateien liegen im S3-Bucket. Nur `nc-html` fuer die Nextcloud-Installation.

- [ ] **Step 2: Validate**

```bash
docker compose config --quiet
```

Expected: no output (valid syntax).

- [ ] **Step 3: Commit**

```bash
git add docker-compose.yml
git commit -m "feat: add Nextcloud stack with S3 objectstore, Redis, Cron"
```

---

## Task 5: docker-compose.yml — Collabora + Coder Stack

**Files:**
- Modify: `docker-compose.yml` (append Collabora and Coder services)

Reference: SPEC.md Sections 11, 12, 8

- [ ] **Step 1: Add Collabora and Coder services to docker-compose.yml**

Append after the Nextcloud section:

```yaml
  # ===========================================================================
  # Collabora CODE
  # ===========================================================================

  collabora:
    image: collabora/code:25.04.9.2.1
    container_name: collabora
    restart: unless-stopped
    env_file: secrets.env
    environment:
      aliasgroup1: "https://${NC_HOSTNAME}:443"
      extra_params: "--o:ssl.enable=false --o:ssl.termination=true"
      username: ${COLLABORA_ADMIN_USER:-admin}
      password: ${COLLABORA_ADMIN_PASSWORD}
      dictionaries: "de_DE en_US"
    networks:
      - proxy
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=proxy"
      # Router
      - "traefik.http.routers.collabora.rule=Host(`${COLLABORA_HOSTNAME}`)"
      - "traefik.http.routers.collabora.entrypoints=websecure"
      - "traefik.http.routers.collabora.tls.certresolver=letsencrypt"
      # Service
      - "traefik.http.services.collabora.loadbalancer.server.port=9980"
      # Middlewares
      - "traefik.http.routers.collabora.middlewares=collabora-headers"
      - "traefik.http.middlewares.collabora-headers.headers.stsSeconds=31536000"
      - "traefik.http.middlewares.collabora-headers.headers.customRequestHeaders.X-Forwarded-Proto=https"
    cap_add:
      - MKNOD
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9980/hosting/discovery"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s
    deploy:
      resources:
        limits:
          memory: 1536M
        reservations:
          memory: 1024M

  # ===========================================================================
  # Coder Remote Development
  # ===========================================================================

  coder-db:
    image: postgres:16-alpine
    container_name: coder-db
    restart: unless-stopped
    env_file: secrets.env
    environment:
      POSTGRES_DB: ${CODER_DB_NAME:-coder}
      POSTGRES_USER: ${CODER_DB_USER:-coder}
      POSTGRES_PASSWORD: ${CODER_DB_PASSWORD:?CODER_DB_PASSWORD muss gesetzt sein}
    volumes:
      - coder-pgdata:/var/lib/postgresql/data
    networks:
      - coder-backend
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${CODER_DB_USER:-coder} -d ${CODER_DB_NAME:-coder}"]
      interval: 15s
      timeout: 5s
      retries: 5
    deploy:
      resources:
        limits:
          memory: 512M
        reservations:
          memory: 256M

  coder:
    image: ghcr.io/coder/coder:v2.30.4
    container_name: coder
    restart: unless-stopped
    env_file: secrets.env
    environment:
      CODER_PG_CONNECTION_URL: "postgresql://${CODER_DB_USER:-coder}:${CODER_DB_PASSWORD}@coder-db/${CODER_DB_NAME:-coder}?sslmode=disable"
      CODER_HTTP_ADDRESS: "0.0.0.0:7080"
      CODER_ACCESS_URL: "https://${CODER_HOSTNAME:-coder.example.de}"
      CODER_WILDCARD_ACCESS_URL: ""
      # Terraform/Hetzner fuer Workspace-Provisionierung
      HCLOUD_TOKEN: ${HCLOUD_TOKEN}
    networks:
      - proxy
      - coder-backend
    depends_on:
      coder-db:
        condition: service_healthy
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=proxy"
      # Router
      - "traefik.http.routers.coder.rule=Host(`${CODER_HOSTNAME}`)"
      - "traefik.http.routers.coder.entrypoints=websecure"
      - "traefik.http.routers.coder.tls.certresolver=letsencrypt"
      # Service
      - "traefik.http.services.coder.loadbalancer.server.port=7080"
      # Headers (kein Rate-Limiting — WebSocket-Traffic)
      - "traefik.http.routers.coder.middlewares=coder-headers"
      - "traefik.http.middlewares.coder-headers.headers.customRequestHeaders.X-Forwarded-Proto=https"
      - "traefik.http.middlewares.coder-headers.headers.stsSeconds=31536000"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:7080/api/v2/buildinfo"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s
    deploy:
      resources:
        limits:
          memory: 1536M
        reservations:
          memory: 768M
```

- [ ] **Step 2: Validate complete compose file**

```bash
docker compose config --quiet
```

Expected: no output (valid syntax). All 10 services should be defined.

- [ ] **Step 3: Verify service count**

```bash
docker compose config --services | wc -l
```

Expected: `10` (openproject-db, openproject-cache, openproject, nextcloud-db, nextcloud-redis, nextcloud, nextcloud-cron, collabora, coder-db, coder)

- [ ] **Step 4: Commit**

```bash
git add docker-compose.yml
git commit -m "feat: add Collabora and Coder stacks, complete docker-compose.yml"
```

---

## Task 6: Database Dump Script

**Files:**
- Create: `dump-databases.sh`

Reference: SPEC.md Section 16

- [ ] **Step 1: Write `dump-databases.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

DUMP_DIR="/opt/containers/documentation-stack/db-dumps"
mkdir -p "$DUMP_DIR"

echo "=== Dumping OpenProject DB ==="
docker exec openproject-db pg_dump \
  -U openproject \
  -d openproject \
  --format=custom \
  --file=/tmp/openproject.dump
docker cp openproject-db:/tmp/openproject.dump "$DUMP_DIR/openproject.dump"
docker exec openproject-db rm /tmp/openproject.dump

echo "=== Putting Nextcloud in Maintenance Mode ==="
docker exec -u www-data nextcloud php occ maintenance:mode --on

echo "=== Dumping Nextcloud DB ==="
docker exec nextcloud-db pg_dump \
  -U nextcloud \
  -d nextcloud \
  --format=custom \
  --file=/tmp/nextcloud.dump
docker cp nextcloud-db:/tmp/nextcloud.dump "$DUMP_DIR/nextcloud.dump"
docker exec nextcloud-db rm /tmp/nextcloud.dump

echo "=== Disabling Nextcloud Maintenance Mode ==="
docker exec -u www-data nextcloud php occ maintenance:mode --off

echo "=== Dumping Coder DB ==="
docker exec coder-db pg_dump \
  -U coder \
  -d coder \
  --format=custom \
  --file=/tmp/coder.dump
docker cp coder-db:/tmp/coder.dump "$DUMP_DIR/coder.dump"
docker exec coder-db rm /tmp/coder.dump

echo "=== Dumps created in $DUMP_DIR ==="
```

- [ ] **Step 2: Make executable**

```bash
chmod +x dump-databases.sh
```

- [ ] **Step 3: Lint with shellcheck**

```bash
shellcheck dump-databases.sh
```

Expected: no warnings/errors.

- [ ] **Step 4: Commit**

```bash
git add dump-databases.sh
git commit -m "feat: add database dump script for all 3 PostgreSQL instances"
```

---

## Task 7: Final Validation and Cleanup

**Files:**
- All files from previous tasks

- [ ] **Step 1: Full compose validation**

```bash
docker compose config --quiet
docker compose config --services | sort
```

Expected services (sorted):
```
coder
coder-db
collabora
nextcloud
nextcloud-cron
nextcloud-db
nextcloud-redis
openproject
openproject-cache
openproject-db
```

- [ ] **Step 2: Verify all networks**

```bash
docker compose config --format json | jq '.networks | keys'
```

Expected: `["coder-backend", "nextcloud-backend", "openproject-backend", "proxy"]`

- [ ] **Step 3: Verify all volumes**

```bash
docker compose config --format json | jq '.volumes | keys'
```

Expected: `["coder-pgdata", "nc-html", "nc-pgdata", "nc-redis", "op-assets", "op-pgdata"]`

- [ ] **Step 4: Verify no nc-data volume exists**

```bash
grep -c "nc-data" docker-compose.yml
```

Expected: `0` — files go to S3, not a local volume.

- [ ] **Step 5: Final commit**

```bash
git add -A
git commit -m "chore: final validation pass on complete stack"
```

---

## Task 8: Post-Deployment Checklist (Manual Steps on Server)

This task is **not automated** — it documents the manual steps to perform after `docker compose up -d` on the target server. Reference: SPEC.md Section 20.

### Prerequisites (before deployment)

- [ ] DNS records configured: `openproject.example.de`, `cloud.example.de`, `office.example.de`, `coder.example.de` → server IP
- [ ] Hetzner Object Storage bucket created, access key generated
- [ ] Hetzner Cloud API token generated (for Coder workspaces)
- [ ] `secrets.env` filled with real values (copy from `secrets.env.example`)
- [ ] `chmod 600 secrets.env && chown root:root secrets.env`
- [ ] Traefik v3 running with `proxy` network and `letsencrypt` certresolver
- [ ] SMTP relay credentials ready (Proton or SMTP2Go)
- [ ] Docker log-rotation configured in `/etc/docker/daemon.json` (SPEC.md Section 19):
  ```json
  { "log-driver": "json-file", "log-opts": { "max-size": "10m", "max-file": "3" } }
  ```

### Deployment

- [ ] `docker compose up -d`
- [ ] `docker compose ps` — all containers `Up (healthy)` or `Up`
- [ ] Wait 2-3 minutes for OpenProject DB migrations on first start

### OpenProject Setup

- [ ] Open `https://openproject.example.de`, login `admin`/`admin`
- [ ] Change admin password immediately
- [ ] Administration → E-Mail: configure SMTP (uncomment SMTP vars in docker-compose.yml, redeploy)
- [ ] Administration → File Storages: add Nextcloud integration (SPEC.md Section 9)

### Nextcloud Setup

- [ ] Open `https://cloud.example.de`, login with `NC_ADMIN_USER`/`NC_ADMIN_PASSWORD`
- [ ] Settings → Administration → Basic Settings: set background jobs to **Cron**
- [ ] Settings → Administration → Basic Settings: configure email server
- [ ] Security check under Settings → Administration → Overview
- [ ] Install apps:
  ```bash
  docker exec -u www-data nextcloud php occ app:install richdocuments
  docker exec -u www-data nextcloud php occ app:install integration_openproject
  docker exec -u www-data nextcloud php occ app:install admin_audit
  docker exec -u www-data nextcloud php occ app:install spreed
  docker exec -u www-data nextcloud php occ app:install whiteboard
  ```
  **Hinweis Whiteboard:** Fuer Echtzeit-Kollaboration (mehrere Nutzer gleichzeitig) wird ein separater Node.js-Backend-Server benoetigt (`nextcloud-whiteboard-server`). Ohne diesen funktionieren Whiteboards nur im Einzelnutzer-Modus. Fuer den Start reicht die App allein — Backend spaeter ergaenzen bei Bedarf (siehe SPEC.md Section 20.3).
- [ ] Configure Nextcloud Office → "Use your own server" → `https://office.example.de`
- [ ] Configure OpenProject Integration → enter OAuth credentials from OP (SPEC.md Section 9)

### Nextcloud Optimierungen

```bash
docker exec -u www-data nextcloud php occ maintenance:repair
docker exec -u www-data nextcloud php occ db:add-missing-indices
docker exec -u www-data nextcloud php occ db:convert-filecache-bigint
docker exec -u www-data nextcloud php occ config:system:set default_phone_region --value="DE"
docker exec -u www-data nextcloud php occ config:system:set maintenance_window_start --type=integer --value=1
```

### Collabora

- [ ] Open `https://office.example.de/hosting/discovery` — should return XML
- [ ] Optional: `https://office.example.de/browser/dist/admin/admin.html` for admin panel

### Coder

- [ ] Open `https://coder.example.de`, create first admin account
- [ ] Import Hetzner Cloud workspace template (reference: `ntimo/coder-hetzner-cloud-template`)
- [ ] Test: create workspace, verify SSH connection

### Monitoring

- [ ] Add Uptime Kuma monitors for all 4 healthcheck URLs (SPEC.md Section 15)
- [ ] Configure ntfy notifications in Uptime Kuma

### Backup

- [ ] Test `dump-databases.sh` manually
- [ ] Configure Borgmatic on server with StorageBox as target (SPEC.md Section 16)
- [ ] Test borgmatic backup + restore cycle

### Restore Test

- [ ] Perform full restore test on a separate server before going to production (SPEC.md Section 17)
