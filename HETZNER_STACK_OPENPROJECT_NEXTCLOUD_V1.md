# Hetzner Stack — OpenProject + Nextcloud

**Version:** 1.0  
**Stand:** März 2026  
**Status:** Bereit zur Umsetzung  
**Abhängigkeiten:** Traefik v3 auf Hetzner vServer

---

## Inhaltsverzeichnis

1. [Übersicht](#1-übersicht)
2. [Architektur](#2-architektur)
3. [Komponenten](#3-komponenten)
4. [Voraussetzungen](#4-voraussetzungen)
5. [Installation](#5-installation)
6. [Traefik-Integration](#6-traefik-integration)
7. [Nach dem Start](#7-nach-dem-start)
8. [Wartung](#8-wartung)
9. [Backup-Integration](#9-backup-integration)
10. [Ressourcen-Abschätzung](#10-ressourcen-abschätzung)
11. [Troubleshooting](#11-troubleshooting)

---

## 1. Übersicht

Dieser Stack stellt OpenProject (Projektmanagement) und Nextcloud (Cloud-Speicher) auf dem Hetzner vServer bereit. Beide Dienste laufen als Docker Compose Stack hinter dem bereits vorhandenen Traefik v3 Reverse Proxy.

| Dienst | Version | Zweck |
|--------|---------|-------|
| **OpenProject** | 17 (Community) | Projektmanagement, Aufgabenverwaltung |
| **Nextcloud** | 32 (Apache) | Cloud-Speicher, CalDAV/CardDAV, Office |

### Design-Entscheidungen

| Entscheidung | Begründung |
|-------------|------------|
| **Getrennte PostgreSQL-Instanzen** | Unabhängige Backups, Updates, Wartung |
| **PostgreSQL 16 für beide** | Gleiche Engine, beide Dienste unterstützen PostgreSQL |
| **Redis für Nextcloud** | File-Locking, Session-Storage, Caching |
| **Memcached für OpenProject** | Von OpenProject empfohlen, niedriger Overhead |
| **Docker Labels für Traefik** | Einfacher als File-Provider bei häufig wechselnden Containern |
| **Named Volumes** | Saubere Trennung, einfaches Backup via `docker volume` |

---

## 2. Architektur

```
                          ┌─────────────────────────────────┐
                          │        INTERNET / DNS           │
                          │  openproject.example.de         │
                          │  cloud.example.de               │
                          └──────────────┬──────────────────┘
                                         │ :443
                          ┌──────────────▼──────────────────┐
                          │         TRAEFIK v3              │
                          │  (bereits deployed, Netz: proxy)│
                          └──┬─────────────────────────┬────┘
                             │                         │
              ┌──────────────▼────────┐   ┌────────────▼──────────────┐
              │   OpenProject :8080   │   │    Nextcloud :80          │
              │   (openproject/       │   │    (nextcloud:32-apache)  │
              │    openproject:17)    │   │                           │
              └──┬──────────┬─────────┘   └──┬──────────┬────────────┘
                 │          │                │          │
    ┌────────────▼──┐  ┌───▼────────┐  ┌────▼──────┐  ┌▼────────────┐
    │ PostgreSQL 16 │  │ Memcached  │  │ Postgres  │  │  Redis 7    │
    │ (openproject) │  │ (128 MB)   │  │ 16 (nc)   │  │  (256 MB)   │
    └───────────────┘  └────────────┘  └───────────┘  └─────────────┘
    
    Netz: openproject-backend          Netz: nextcloud-backend
    
                          ┌──────────────────────┐
                          │  nextcloud-cron       │
                          │  (Hintergrund-Jobs)   │
                          └──────────────────────┘
```

---

## 3. Komponenten

### OpenProject Stack

| Container | Image | Netzwerk(e) | Funktion |
|-----------|-------|-------------|----------|
| `openproject` | `openproject/openproject:17` | proxy, openproject-backend | App-Server (Web + Worker + Cron) |
| `openproject-db` | `postgres:16-alpine` | openproject-backend | Datenbank |
| `openproject-cache` | `memcached:1-alpine` | openproject-backend | Session/Object Cache |

### Nextcloud Stack

| Container | Image | Netzwerk(e) | Funktion |
|-----------|-------|-------------|----------|
| `nextcloud` | `nextcloud:32-apache` | proxy, nextcloud-backend | App-Server (Apache + PHP) |
| `nextcloud-db` | `postgres:16-alpine` | nextcloud-backend | Datenbank |
| `nextcloud-redis` | `redis:7-alpine` | nextcloud-backend | Cache, Locking, Sessions |
| `nextcloud-cron` | `nextcloud:32-apache` | nextcloud-backend | Cron-Jobs (alle 5 Min.) |

---

## 4. Voraussetzungen

### Hetzner vServer

- Docker Engine + Docker Compose Plugin installiert
- Traefik v3 läuft im externen Docker-Netzwerk `proxy`
- DNS-Records für beide Domains zeigen auf die Server-IP
- Let's Encrypt Resolver `letsencrypt` in Traefik konfiguriert
- Mindestens 4 GB RAM empfohlen (besser 8 GB)

### DNS-Einträge

```
openproject.example.de    A    <HETZNER-IP>
cloud.example.de          A    <HETZNER-IP>
```

### Traefik Netzwerk

Falls das externe Netzwerk `proxy` noch nicht existiert:

```bash
docker network create proxy
```

---

## 5. Installation

### 5.1 Repository / Verzeichnis anlegen

```bash
mkdir -p /opt/containers/hetzner-stack
cd /opt/containers/hetzner-stack
```

### 5.2 Dateien ablegen

Folgende Dateien in das Verzeichnis kopieren:

```
hetzner-stack/
├── docker-compose.yml
├── secrets.env.example
├── secrets.env           ← manuell erstellen!
└── .gitignore
```

### 5.3 Secrets konfigurieren

```bash
cp secrets.env.example secrets.env

# Sichere Passwörter generieren
echo "OP_DB_PASSWORD=$(openssl rand -base64 32)" 
echo "OP_SECRET_KEY_BASE=$(openssl rand -hex 64)"
echo "NC_DB_PASSWORD=$(openssl rand -base64 32)"
echo "NC_REDIS_PASSWORD=$(openssl rand -base64 32)"
```

Die generierten Werte in `secrets.env` eintragen und Domains anpassen.

### 5.4 .gitignore

```bash
cat > .gitignore << 'EOF'
secrets.env
*.log
EOF
```

### 5.5 Stack starten

```bash
cd /opt/containers/hetzner-stack

# Images pullen
docker compose pull

# Stack starten
docker compose up -d

# Logs verfolgen (OpenProject braucht 1-3 Minuten für Erststart)
docker compose logs -f
```

### 5.6 Status prüfen

```bash
docker compose ps
docker compose logs openproject | tail -20
docker compose logs nextcloud | tail -20
```

---

## 6. Traefik-Integration

### Variante A: Docker Labels (Standard im Compose-File)

Die `docker-compose.yml` nutzt Traefik Docker Labels. Dafür muss Traefik den Docker Provider aktiviert haben:

```yaml
# In der Traefik-Konfiguration (traefik.yaml):
providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false
    network: proxy
```

### Variante B: File-Provider (dynamic.yaml)

Falls du auf dem Hetzner wie auf dem NUC den File-Provider bevorzugst, entferne alle `labels:` aus der `docker-compose.yml` und ergänze stattdessen in deiner `dynamic.yaml`:

```yaml
http:
  routers:
    openproject:
      rule: "Host(`openproject.example.de`)"
      entryPoints:
        - websecure
      service: openproject
      tls:
        certResolver: letsencrypt
      middlewares:
        - openproject-headers

    nextcloud:
      rule: "Host(`cloud.example.de`)"
      entryPoints:
        - websecure
      service: nextcloud
      tls:
        certResolver: letsencrypt
      middlewares:
        - nextcloud-chain

  services:
    openproject:
      loadBalancer:
        servers:
          - url: "http://openproject:8080"

    nextcloud:
      loadBalancer:
        servers:
          - url: "http://nextcloud:80"

  middlewares:
    openproject-headers:
      headers:
        customRequestHeaders:
          X-Forwarded-Proto: "https"
        stsSeconds: 31536000
        stsIncludeSubdomains: true

    nextcloud-redirectregex:
      redirectRegex:
        permanent: true
        regex: "https://(.*)/.well-known/(?:card|cal)dav"
        replacement: "https://${1}/remote.php/dav"

    nextcloud-headers:
      headers:
        stsSeconds: 31536000
        stsIncludeSubdomains: true
        stsPreload: true
        customRequestHeaders:
          X-Forwarded-Proto: "https"

    nextcloud-chain:
      chain:
        middlewares:
          - nextcloud-redirectregex
          - nextcloud-headers
```

**Wichtig bei File-Provider:** Die Container müssen trotzdem im `proxy`-Netzwerk sein, damit Traefik sie über den Container-Namen auflösen kann.

---

## 7. Nach dem Start

### 7.1 OpenProject

1. Öffne `https://openproject.example.de`
2. Standard-Login: `admin` / `admin`
3. **Sofort das Passwort ändern!**
4. Sprache auf Deutsch stellen (sollte default sein via `OPENPROJECT_DEFAULT__LANGUAGE`)
5. Unter Administration → E-Mail: SMTP konfigurieren falls gewünscht

### 7.2 Nextcloud

1. Öffne `https://cloud.example.de`
2. Login mit den in `secrets.env` gesetzten `NC_ADMIN_USER` / `NC_ADMIN_PASSWORD`
3. Unter Einstellungen → Verwaltung → Grundeinstellungen prüfen:
   - Hintergrund-Aufgaben: **Cron** auswählen (läuft über `nextcloud-cron` Container)
   - E-Mail-Server konfigurieren falls gewünscht
4. Sicherheits-Check unter Einstellungen → Verwaltung → Übersicht

### 7.3 Nextcloud Optimierungen nach Erstinstallation

```bash
# In den Container
docker exec -u www-data nextcloud php occ maintenance:repair
docker exec -u www-data nextcloud php occ db:add-missing-indices
docker exec -u www-data nextcloud php occ db:convert-filecache-bigint

# Phone-Region setzen (DE)
docker exec -u www-data nextcloud php occ config:system:set default_phone_region --value="DE"

# Maintenance-Window setzen (nachts)
docker exec -u www-data nextcloud php occ config:system:set maintenance_window_start --type=integer --value=1
```

---

## 8. Wartung

### Updates

```bash
cd /opt/containers/hetzner-stack

# Neue Images ziehen
docker compose pull

# Stack neu starten (Zero-Downtime bei Traefik)
docker compose up -d

# Aufräumen
docker image prune -f
```

**Hinweis:** Bei Major-Version-Upgrades (z.B. Nextcloud 32 → 33 oder OpenProject 17 → 18) vorher die Release-Notes lesen und ein Backup erstellen!

### Nextcloud occ-Befehle

```bash
# Status
docker exec -u www-data nextcloud php occ status

# Maintenance-Modus
docker exec -u www-data nextcloud php occ maintenance:mode --on
docker exec -u www-data nextcloud php occ maintenance:mode --off

# App-Updates
docker exec -u www-data nextcloud php occ app:update --all
```

### OpenProject CLI

```bash
# Rails Console (Vorsicht!)
docker exec -it openproject bash -c "RAILS_ENV=production bundle exec rails console"

# Seed-Daten neu laden
docker exec -it openproject bash -c "RAILS_ENV=production bundle exec rake db:seed"
```

### Logs

```bash
# Alle Logs
docker compose logs -f

# Einzelne Services
docker compose logs -f openproject
docker compose logs -f nextcloud

# Nextcloud-internes Log
docker exec -u www-data nextcloud php occ log:tail
```

---

## 9. Backup-Integration

### Volumes sichern

Die relevanten Docker Volumes für Borgmatic/BorgBackup:

| Volume | Inhalt | Priorität |
|--------|--------|-----------|
| `op-pgdata` | OpenProject DB | Kritisch |
| `op-assets` | OpenProject Dateien | Kritisch |
| `nc-pgdata` | Nextcloud DB | Kritisch |
| `nc-data` | Nextcloud User-Dateien | Kritisch |
| `nc-html` | Nextcloud Installation | Wichtig |
| `nc-redis` | Redis AOF | Nice-to-have |

### Datenbank-Dumps (empfohlen vor Volume-Backup)

```bash
#!/bin/bash
# dump-databases.sh — Vor Borgmatic-Lauf ausführen

DUMP_DIR="/opt/containers/hetzner-stack/db-dumps"
mkdir -p "$DUMP_DIR"

# OpenProject
docker exec openproject-db pg_dump \
  -U openproject \
  -d openproject \
  --format=custom \
  --file=/tmp/openproject.dump
docker cp openproject-db:/tmp/openproject.dump "$DUMP_DIR/openproject.dump"

# Nextcloud (Maintenance-Modus aktivieren!)
docker exec -u www-data nextcloud php occ maintenance:mode --on
docker exec nextcloud-db pg_dump \
  -U nextcloud \
  -d nextcloud \
  --format=custom \
  --file=/tmp/nextcloud.dump
docker cp nextcloud-db:/tmp/nextcloud.dump "$DUMP_DIR/nextcloud.dump"
docker exec -u www-data nextcloud php occ maintenance:mode --off

echo "Dumps erstellt in $DUMP_DIR"
```

### Borgmatic-Einbindung

Diesen Pfad in die Borgmatic-Konfiguration auf dem Hetzner aufnehmen:

```yaml
# borgmatic config
source_directories:
  - /opt/containers/hetzner-stack/db-dumps
  - /var/lib/docker/volumes/hetzner-stack_op-assets
  - /var/lib/docker/volumes/hetzner-stack_nc-data
  - /var/lib/docker/volumes/hetzner-stack_nc-html

before_backup:
  - /opt/containers/hetzner-stack/dump-databases.sh
```

---

## 10. Ressourcen-Abschätzung

### RAM

| Komponente | Geschätzt |
|-----------|-----------|
| OpenProject (Web+Worker+Cron) | ~1.5 GB |
| OpenProject PostgreSQL | ~0.3 GB |
| Memcached | ~0.15 GB |
| Nextcloud (Apache+PHP) | ~0.5 GB |
| Nextcloud PostgreSQL | ~0.3 GB |
| Redis | ~0.1 GB |
| Nextcloud Cron | ~0.1 GB |
| **Gesamt (nur dieser Stack)** | **~3.0 GB** |

Zusammen mit den bereits geplanten Diensten (Headscale, Uptime Kuma, ntfy, Healthchecks) sind ca. 4.5 GB RAM auf dem Hetzner vServer zu erwarten. Ein vServer mit **8 GB RAM** ist empfehlenswert.

### Disk

| Daten | Größe (initial) |
|-------|-----------------|
| OpenProject Images + Assets | ~2 GB |
| Nextcloud Images + Installation | ~1.5 GB |
| PostgreSQL-Daten (initial) | ~0.5 GB |
| **Gesamt ohne User-Daten** | **~4 GB** |

Der Speicherbedarf wächst mit der Nutzung — besonders die Nextcloud-Daten (`nc-data`).

---

## 11. Troubleshooting

### OpenProject zeigt ERR_SSL_PROTOCOL_ERROR

OpenProject erwartet standardmäßig HTTPS. Sicherstellen, dass:
- `OPENPROJECT_HTTPS=true` gesetzt ist
- Traefik TLS terminiert und den Traffic als HTTP an Port 8080 weiterleitet
- Der `X-Forwarded-Proto: https` Header gesetzt wird

### Nextcloud "Access through untrusted domain"

```bash
docker exec -u www-data nextcloud php occ config:system:set \
  trusted_domains 0 --value="cloud.example.de"
```

### Nextcloud "The reverse proxy header configuration is incorrect"

Prüfen, dass `TRUSTED_PROXIES` die Docker-Netzwerk-Bereiche abdeckt und `OVERWRITEPROTOCOL=https` gesetzt ist.

### OpenProject-DB-Migration hängt beim Erststart

OpenProject braucht beim ersten Start 1-3 Minuten für DB-Migrationen. Geduld und Logs prüfen:

```bash
docker compose logs -f openproject 2>&1 | grep -i "migrat"
```

### Redis-Verbindung schlägt fehl

```bash
# Redis-Passwort prüfen
docker exec nextcloud-redis redis-cli -a "$NC_REDIS_PASSWORD" ping
# Erwartet: PONG
```

### Container-Netzwerk-Probleme

```bash
# Prüfen ob proxy-Netzwerk existiert
docker network ls | grep proxy

# Container im Netzwerk anzeigen
docker network inspect proxy
```

---

## Anhang: Dateistruktur

```
/opt/containers/hetzner-stack/
├── docker-compose.yml        ← Stack-Definition
├── secrets.env               ← Secrets (NICHT in Git!)
├── secrets.env.example       ← Template für secrets.env
├── .gitignore                ← secrets.env ausschließen
├── db-dumps/                 ← Datenbank-Dumps (von Backup-Script)
│   ├── openproject.dump
│   └── nextcloud.dump
└── HETZNER_STACK_OPENPROJECT_NEXTCLOUD_V1.md   ← Diese Doku
```
