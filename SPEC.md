# Documentation Stack — OpenProject + Nextcloud + Collabora + Coder

**Version:** 2.3
**Stand:** Maerz 2026
**Status:** Spezifikation abgeschlossen, bereit zur Umsetzung
**Abhaengigkeiten:** Traefik v3 auf OVH Dedicated Server (RISE-S), Hetzner Cloud API (fuer Coder Workspaces), Hetzner StorageBox (Backups)

---

## Inhaltsverzeichnis

1. [Kontext und Ziele](#1-kontext-und-ziele)
2. [Architektur](#2-architektur)
3. [Komponenten](#3-komponenten)
4. [Design-Entscheidungen](#4-design-entscheidungen)
5. [Infrastruktur-Optionen](#5-infrastruktur-optionen)
6. [Voraussetzungen](#6-voraussetzungen)
7. [Konfiguration](#7-konfiguration)
8. [Traefik-Integration](#8-traefik-integration)
9. [OpenProject-Nextcloud-Integration](#9-openproject-nextcloud-integration)
10. [Nextcloud Speicher (Lokal)](#10-nextcloud-speicher-lokal)
11. [Collabora Online](#11-collabora-online)
12. [Coder Remote Development](#12-coder-remote-development)
13. [Resource Limits](#13-resource-limits)
14. [Sicherheit](#14-sicherheit)
15. [Monitoring-Integration](#15-monitoring-integration)
16. [Backup-Strategie](#16-backup-strategie)
17. [Restore-Prozedur](#17-restore-prozedur)
18. [DSGVO und Compliance](#18-dsgvo-und-compliance)
19. [Wartung und Updates](#19-wartung-und-updates)
20. [Nach dem Start](#20-nach-dem-start)
21. [Roadmap: Zukuenftige Dienste](#21-roadmap-zukuenftige-dienste)
22. [Troubleshooting](#22-troubleshooting)

---

## 1. Kontext und Ziele

### Ausgangslage

Dokumentations- und Projektmanagement-Stack fuer eine neu zu gruendende IT-Beratung (1-5 Personen). Der Stack laeuft auf einem dedizierten OVH RISE-S Server (Frankfurt, Deutschland).

### Ziele

- Zentrales Projektmanagement mit OpenProject (Aufgaben, Gantt, Meetings, Wiki)
- Cloud-Speicher mit Nextcloud (Dateien, Kalender, Kontakte, Freigaben)
- Dokumentenbearbeitung im Browser ueber Collabora Online
- Direkte Verknuepfung zwischen Projektaufgaben und Dateien (OpenProject-Nextcloud-Integration)
- Lokaler NVMe-Speicher fuer Nextcloud (S3-Migration spaeter moeglich)
- Remote-Entwicklungsumgebungen mit Coder (Management auf diesem Server, Workspaces extern)
- DSGVO-konforme Verarbeitung von Kundendaten

### Nicht-Ziele

- Eigener Mailserver (externer Transactional-Mail-Provider)
- LDAP/SSO (bei 1-5 Personen nicht noetig, nachruestbar)
- High-Availability oder Multi-Node-Setup
- Watchtower oder automatische Updates (bewusst manuell)

---

## 2. Architektur

```
                          +----------------------------------+
                          |        INTERNET / DNS            |
                          |  openproject.example.de          |
                          |  cloud.example.de                |
                          |  office.example.de               |
                          |  coder.example.de                |
                          +---------------+------------------+
                                          | :443
                          +---------------v------------------+
                          |          TRAEFIK v3              |
                          |  (Netz: proxy + socket-proxy)    |
                          |  + Rate-Limiting Middlewares      |
                          |  + Docker Socket Proxy (tecnativa)|
                          +--+-------+-------+--------+------+
                             |       |       |        |
          +------------------v-+ +---v----+  +-v-----------+ +-v-----------+
          |  OpenProject :8080 | |Nextcl. |  |Collabora    | |Coder :7080 |
          |  (17.2.1)          | |:80     |  |CODE :9980   | |(coderd)    |
          |  + Hocuspocus      | |(32.0)  |  |             | |            |
          +--+----------+------+ +--+--+--+  +-------------+ +--+---------+
             |          |          |    |                        |
   +---------v-+ +------v----+ +--v--+ +v----------+   +-------v------+
   |Postgres 18| | Memcached | |PG 18| | Redis 7   |   |Postgres 18   |
   |(op)       | | (128 MB)  | |(nc) | | (256 MB)  |   |(coder)       |
   +------------+ +----------+ +-----+ +-----------+   +--------------+

   Netz: op-backend          Netz: nc-backend          Netz: coder-backend

          OpenProject <--- OAuth ---> Nextcloud
          Nextcloud -----> Lokaler NVMe-Speicher (nc-data Volume)
          Coder -----> Hetzner Cloud API (Workspace-VMs)
          Coder -----> Lokaler Docker Socket (Container-Workspaces via coder-socket-proxy)
          Coder -----> Docker auf festem Dev-Server (Container-Workspaces, optional)

          +------------------+
          | nextcloud-cron   |
          | (Hintergrund)    |
          +------------------+
```

### Netzwerk-Topologie

| Netzwerk | Typ | Angeschlossene Container |
|----------|-----|--------------------------|
| `proxy` | extern | traefik, openproject, nextcloud, collabora, coder |
| `socket-proxy` | intern | socket-proxy, traefik |
| `coder-socket-proxy` | intern | coder-socket-proxy, coder |
| `openproject-backend` | intern | openproject, openproject-db, openproject-cache |
| `nextcloud-backend` | intern | nextcloud, nextcloud-db, nextcloud-redis, nextcloud-cron |
| `coder-backend` | intern | coder, coder-db |

Collabora braucht kein eigenes Backend-Netzwerk — es kommuniziert ausschliesslich ueber HTTP/WebSocket mit Nextcloud via das `proxy`-Netzwerk.

---

## 3. Komponenten

### Image-Versionen (exakt gepinnt)

| Container | Image | Version |
|-----------|-------|---------|
| `socket-proxy` | `tecnativa/docker-socket-proxy` | `0.3.0` |
| `coder-socket-proxy` | `tecnativa/docker-socket-proxy` | `0.3.0` |
| `traefik` | `traefik` | `v3.6.9` |
| `openproject` | `openproject/openproject` | `17.2.1` |
| `openproject-db` | `postgres` | `18.3-alpine` |
| `openproject-cache` | `memcached` | `1.6.41-alpine` |
| `nextcloud` | `nextcloud` | `32.0.6-apache` |
| `nextcloud-db` | `postgres` | `18.3-alpine` |
| `nextcloud-redis` | `redis` | `7.4.8-alpine` |
| `nextcloud-cron` | `nextcloud` | `32.0.6-apache` |
| `collabora` | `collabora/code` | `25.04.9.3.1` |
| `coder` | `ghcr.io/coder/coder` | `v2.30.4` |
| `coder-db` | `postgres` | `18.3-alpine` |

Versionen werden mit Renovate oder manuell getrackt. Alle Images sind auf exakte Patch-Versionen gepinnt. Vor jedem Update Release-Notes lesen.

### OpenProject Stack

| Container | Netzwerk(e) | Funktion |
|-----------|-------------|----------|
| `openproject` | proxy, openproject-backend | App-Server (Web + Worker + Cron + Hocuspocus) |
| `openproject-db` | openproject-backend | PostgreSQL-Datenbank |
| `openproject-cache` | openproject-backend | Memcached (Session/Object Cache) |

OpenProject 17.2 bringt Hocuspocus fuer Real-Time Document Collaboration mit. In Docker-Compose-Setups laeuft dieser automatisch als Teil des App-Containers. **Hinweis:** OpenProject 17.2.1 enthaelt einen kritischen Security-Fix (CVE-2026-32698, SQL Injection → RCE) — nicht aeltere Versionen verwenden.

### Nextcloud Stack

| Container | Netzwerk(e) | Funktion |
|-----------|-------------|----------|
| `nextcloud` | proxy, nextcloud-backend | App-Server (Apache + PHP) |
| `nextcloud-db` | nextcloud-backend | PostgreSQL-Datenbank |
| `nextcloud-redis` | nextcloud-backend | Cache, File-Locking, Sessions |
| `nextcloud-cron` | nextcloud-backend | Hintergrund-Jobs (alle 5 Min.) |

### Collabora Stack

| Container | Netzwerk(e) | Funktion |
|-----------|-------------|----------|
| `collabora` | proxy | Collabora Online Development Edition (CODE) |

### Coder Stack

| Container | Netzwerk(e) | Funktion |
|-----------|-------------|----------|
| `coder` | proxy, coder-backend, coder-socket-proxy | coderd Control Plane (Web-UI, API, built-in Provisioner) |
| `coder-socket-proxy` | coder-socket-proxy | Docker Socket Proxy (read/write fuer Container-Provisionierung) |
| `coder-db` | coder-backend | PostgreSQL-Datenbank fuer Coder |

Coder kann Workspaces sowohl auf **externen Hetzner-Cloud-VMs** als auch als **lokale Docker-Container** auf diesem Server provisionieren. Der Zugriff auf den lokalen Docker-Daemon erfolgt ueber einen dedizierten Socket-Proxy mit eingeschraenkten Berechtigungen (kein Zugriff auf Swarm, Services, Secrets).

---

## 4. Design-Entscheidungen

| Entscheidung | Begruendung |
|-------------|------------|
| **Getrennte PostgreSQL-Instanzen** | Unabhaengige Backups, Updates, Wartung |
| **PostgreSQL 18 fuer alle Dienste** | Gleiche Engine, alle drei Dienste unterstuetzen PostgreSQL |
| **Redis fuer Nextcloud** | File-Locking, Session-Storage, Caching |
| **Memcached fuer OpenProject** | Von OpenProject empfohlen, niedriger Overhead |
| **Collabora CODE statt OnlyOffice** | Bessere Nextcloud-Integration, geringerer RAM-Bedarf |
| **Lokaler NVMe-Speicher fuer Nextcloud** | Maximale Performance, einfaches Setup, spaeterer Wechsel auf S3 moeglich |
| **OpenProject-Nextcloud OAuth** | Dateien direkt an Work Packages verknuepfen |
| **Docker Labels fuer Traefik** | Einfacher als File-Provider bei mehreren Containern |
| **Named Volumes** | Saubere Trennung, einfaches Backup via `docker volume` |
| **.env fuer Docker Compose** | Pragmatisch fuer kleines Team, alle Images kompatibel, Proton Pass CLI generiert .env aus Template |
| **Exakte Image-Versionen** | Keine ueberraschenden Breaking Changes bei `docker compose pull` |
| **Resource Limits** | Schutz vor OOM-Kill des gesamten Servers |
| **Externer SMTP-Relay (Proton/SMTP2Go)** | Kein Wartungsaufwand fuer eigenen Mailserver |
| **Coder Control Plane + lokale Workspaces** | Control Plane lokal, Workspaces wahlweise lokal (Docker) oder extern (Hetzner Cloud VMs) |
| **Coder eigene PostgreSQL** | Konsistent mit OP/NC, unabhaengige Wartung |
| **Coder built-in Provisioner** | Einfach fuer 1-5 User, externer Provisioner spaeter nachruestbar |
| **Zwei Workspace-Templates** | Hetzner-VMs (on-demand) + lokale Docker-Container |
| **Separater Socket-Proxy fuer Coder** | Traefik-Proxy bleibt read-only, Coder bekommt eigenen Proxy mit Schreibzugriff — Principle of Least Privilege |

---

## 5. Infrastruktur-Optionen

### Gewaehlte Option: OVH RISE-S Dedicated Server

| Eigenschaft | Wert |
|-------------|------|
| **Modell** | OVH RISE-S (Sonderangebot) |
| **CPU** | AMD Ryzen 7 9700X, 8C/16T, Zen 5 (Granite Ridge), bis 5.5 GHz Boost |
| **RAM** | 64 GB DDR5 5200 MHz |
| **Storage** | 2x 512 GB NVMe SSD, Software-RAID 1 |
| **Anbindung** | 1 GBit/s oeffentlich, unmetered und garantiert |
| **Standort** | Frankfurt, Deutschland |
| **Preis** | **€77,99/Mo** inkl. MwSt. (€65,54 netto) |
| **Setup** | **€0** (keine Installationsgebuehren) |
| **IPMI** | Ja (Remote-KVM-Konsole) |
| **Kuehlung** | Wasserkuehlung |
| **SLA** | 99,9% |

**Vorteile:**
- Beste Single-Core-Performance im Preissegment (~3348 Geekbench 6 SC, Zen 5)
- 32 MB L3-Cache (doppelt so viel wie vergleichbare APU-CPUs — relevant fuer Datenbank- und PHP-Workloads)
- 64 GB DDR5 ab Werk — 7x mehr als der Stack benoetigt (~9 GB Limits)
- **Keine Setup-Gebuehr** — sofort kosteneffizient
- **IPMI** — Remote-KVM bei Boot-Problemen, unbezahlbar ohne physischen Zugang
- **Wasserkuehlung** — stabilere Boost-Frequenzen unter Dauerlast, leiser
- Standort Frankfurt — niedrige Latenz fuer deutsche Nutzer, Daten in Deutschland (DSGVO)
- Genug Headroom fuer zusaetzliche Dienste (Jitsi, Mattermost, Whisper.cpp)
- Lokale Transkription (CPU-basiert, Whisper.cpp `medium`-Modell laeuft in ~Echtzeit auf 8 Zen-5-Kernen)

**Nachteile:**
- **Kein Hetzner-Oekosystem** — Coder-Workspaces (Hetzner Cloud API) und Object Storage (Hetzner) laufen bei einem anderen Provider. Funktioniert problemlos, aber zwei AVVs, zwei Support-Kanaele
- **Keine API** — kein Terraform fuer den Server selbst, keine Snapshots
- **Hardware-Ausfall = Downtime** — OVH tauscht Hardware, aber das dauert Stunden (keine Live-Migration)
- Feste Lokation, kein schnelles Hoch-/Runterskalieren
- Die minimale iGPU (2 CUs, RDNA 2) und fehlende NPU sind fuer KI-Workloads nicht nutzbar — Transkription laeuft rein CPU-basiert

**Hinweis zur CPU:** Der Ryzen 7 9700X ist eine reine Desktop-CPU (Granite Ridge), kein APU. Er hat **keine nutzbare iGPU** (nur 2 CUs fuer Display-Output/IPMI) und **keine NPU**. OVH bewirbt die "aktivierte GPU" — das bezieht sich auf die IPMI-KVM-Funktion, nicht auf GPU-Compute.

### Preis-Leistungs-Vergleich (Geekbench 6 Single-Core pro Euro)

| Server | CPU | GB6 SC | €/Mo inkl. | SC/€ | Bewertung |
|--------|-----|--------|-----------|------|-----------|
| OVH SYS-1 | Xeon E-2136, 6C/12T | ~1650 | €35,99 | 45,8 | Bestes Ratio, aber absolut zu schwach |
| **OVH RISE-S** | **Ryzen 7 9700X, 8C/16T** | **~3348** | **€77,99** | **42,9** | **Bester Kompromiss aus Ratio und Absolutleistung** |
| OVH SYS-3 (32GB) | Xeon E-2388G, 8C/16T | ~2100 | €49,99 | 42,0 | Nur 32 GB Basis-RAM |
| Hetzner AX42-U | Ryzen 7 PRO 8700GE, 8C/16T | ~2692 | €68,19 | 39,5 | 19% langsamer, teurer ab 04/2026 |
| OVH RISE-M | Ryzen 9 9900X, 12C/24T | ~3500 | €118,99 | 29,4 | +4,5% SC fuer +53% Preis |

### Verworfene Alternativen

| Server | CPU | RAM | Preis inkl./Mo | Grund fuer Ablehnung |
|--------|-----|-----|---------------|---------------------|
| Hetzner AX42-U | Ryzen 7 PRO 8700GE (Zen 4), 8C/16T | 64 GB DDR5 | €68,19 (ab 04/2026) + €127 Setup | 19% weniger SC, 16 MB L3 statt 32 MB, Setup-Gebuehr, kein IPMI |
| Hetzner AX41-NVMe | Ryzen 5 3600 (Zen 2), 6C/12T | 64 GB DDR4 | €44,39 | Zen 2 zu alt, ~50% weniger SC als 9700X |
| OVH KS-6 | EPYC 7351P (Zen 1), 16C/32T | 128-256 GB | €46,99 | SC zu schwach (~950), nur 500 Mbit/s, >6J alte Hardware |
| OVH SYS-3 (64GB) | Xeon E-2388G, 8C/16T | 64 GB | ~€62 | 37% weniger SC als 9700X, kein Preisvorteil mit RAM-Upgrade |
| OVH RISE-M | Ryzen 9 9900X (Zen 5), 12C/24T | 64 GB DDR5 | €118,99 | Nur 4,5% mehr SC fuer 53% Mehrkosten — lohnt erst bei Multi-Core-Bedarf |
| Hetzner CCX33 | EPYC 7003 (vCPU), 8 dedicated | 32 GB | ~€62 (ab 04/2026) | Weniger RAM, weniger Storage, Cloud-Preiserhoehung 30% |

### Nicht empfohlen: Kubernetes-Cluster (vorerst)

Ein 3+3 k3s-Cluster (3 Control Plane + 3 Worker) auf Hetzner Cloud wuerde ~€70-160/Monat kosten (nach Preiserhoehung 04/2026) — deutlich mehr als ein Dedicated Server. Fuer 1-5 User mit internen Tools ist das Overkill. Der Docker-Compose-Stack ist jederzeit auf Kubernetes migrierbar (Helm Charts existieren fuer alle Dienste), falls Wachstum oder Kunden-Anforderungen das rechtfertigen.

---

## 6. Voraussetzungen

### OVH RISE-S Dedicated Server

- **64 GB RAM** (Stack Limits ~9.0 GB — grosszuegiger Headroom fuer zusaetzliche Dienste)
- Docker Engine + Docker Compose Plugin (v2.20+)
- Traefik v3 laeuft im externen Docker-Netzwerk `proxy`
- Let's Encrypt Resolver `letsencrypt` in Traefik konfiguriert

### Partitionierung (bei OVH-Installation konfigurieren)

| Nr | Dateisystem | Mountpunkt | RAID | Groesse | Zweck |
|----|-------------|------------|------|---------|-------|
| 1 | ext4 | `/boot` | RAID-1 | 1 GiB | Bootloader/Kernel |
| 2 | ext4 | `/` | RAID-1 | ~470 GiB | Root + Docker + Daten |
| 3 | swap | swap | RAID-1 | 4 GiB | Safety Net bei OOM |

- **RAID-1** auf allen Partitionen (Spiegelung ueber beide NVMe, von OVH verwaltet)
- **Effektiv nutzbar: ~470 GiB** (RAID-1 = halbe Rohkapazitaet)
- **Eine Root-Partition** statt separater `/var`, `/opt` — flexibler, da Docker-Images und Nutzer-Dateien unterschiedlich schnell wachsen
- **4 GiB Swap** statt 512 MiB (OVH-Default) — gibt mehr Zeit zum Reagieren bevor der OOM-Killer zuschlaegt
- **ext4** statt btrfs/ZFS — ausgereift, beste PostgreSQL-Performance, kein Zusatzaufwand

### Hetzner Cloud API (fuer Coder Workspaces)

- Hetzner Cloud API Token (Read/Write) generiert
- SSH-Key in Hetzner Cloud hinterlegt (fuer Workspace-VMs)
- Optional: Fester Dev-Server mit Docker fuer Container-Workspaces

### DNS-Eintraege

```
openproject.example.de    A    <OVH-SERVER-IP>
cloud.example.de          A    <OVH-SERVER-IP>
office.example.de         A    <OVH-SERVER-IP>
coder.example.de          A    <OVH-SERVER-IP>
traefik.example.de        A    <OVH-SERVER-IP>
```

### Traefik-Netzwerk

```bash
docker network create proxy
```

### SMTP-Relay

SMTP-Relay (Proton oder SMTP2Go) mit:
- SMTP-Host, Port, Credentials
- Verifizierte Absender-Domain

---

## 7. Konfiguration

### Verzeichnisstruktur

```
/opt/containers/novabrands-mgmt/
|-- docker-compose.yml
|-- .env                      <- NICHT in Git! chmod 600 (Docker Compose laedt automatisch)
|-- .env.template            <- Template mit pass:// Referenzen (in Git)
|-- .gitignore
|-- dump-databases.sh         <- Backup-Script
`-- db-dumps/                 <- Datenbank-Dumps
    |-- openproject.dump
    |-- nextcloud.dump
    `-- coder.dump
```

### .env (Secrets)

```bash
# -------------------------------------------------------------------
# Domains
# -------------------------------------------------------------------
OP_HOSTNAME=openproject.example.de
NC_HOSTNAME=cloud.example.de
COLLABORA_HOSTNAME=office.example.de

# -------------------------------------------------------------------
# OpenProject
# -------------------------------------------------------------------
OP_DB_NAME=openproject
OP_DB_USER=openproject
OP_DB_PASSWORD=           # openssl rand -base64 32
OP_SECRET_KEY_BASE=       # openssl rand -hex 64
OP_RAILS_MIN_THREADS=4
OP_RAILS_MAX_THREADS=16

# -------------------------------------------------------------------
# Nextcloud
# -------------------------------------------------------------------
NC_DB_NAME=nextcloud
NC_DB_USER=nextcloud
NC_DB_PASSWORD=           # openssl rand -base64 32
NC_REDIS_PASSWORD=        # openssl rand -base64 32
NC_ADMIN_USER=admin
NC_ADMIN_PASSWORD=        # Sicheres Admin-Passwort waehlen

# -------------------------------------------------------------------
# Coder
# -------------------------------------------------------------------
CODER_HOSTNAME=coder.example.de
CODER_DB_NAME=coder
CODER_DB_USER=coder
CODER_DB_PASSWORD=        # openssl rand -base64 32
HCLOUD_TOKEN=             # Hetzner Cloud API Token (Read/Write)

# -------------------------------------------------------------------
# Collabora
# -------------------------------------------------------------------
# COLLABORA_DOMAIN nicht noetig — aliasgroup1 nutzt NC_HOSTNAME direkt

# -------------------------------------------------------------------
# SMTP (Proton oder SMTP2Go)
# -------------------------------------------------------------------
SMTP_HOST=smtp.example.de
SMTP_PORT=587
SMTP_USER=noreply@example.de
SMTP_PASSWORD=
SMTP_FROM=noreply@example.de
SMTP_DOMAIN=example.de

# -------------------------------------------------------------------
# Collabora Admin (optional)
# -------------------------------------------------------------------
COLLABORA_ADMIN_USER=admin
COLLABORA_ADMIN_PASSWORD=    # openssl rand -base64 16
```

### Dateiberechtigungen

```bash
chmod 600 .env
```

### .gitignore

```
.env
*.log
db-dumps/
```

---

## 8. Traefik-Integration

Alle vier oeffentlichen Dienste nutzen Docker Labels fuer Traefik. OpenProject, Nextcloud und Collabora werden hier beschrieben — Coder-Labels stehen in Abschnitt 12.

### OpenProject

```yaml
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
```

### Nextcloud

```yaml
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
```

### Collabora

```yaml
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
```

### Rate-Limiting

Die Rate-Limit-Middleware wird auf dem Traefik-Container definiert (global verfuegbar) und von den OpenProject-, Nextcloud- und Dashboard-Routern referenziert:

```yaml
# Auf dem Traefik-Container (wird einmal definiert, von mehreren Routern genutzt):
- "traefik.http.middlewares.rate-limit.ratelimit.average=200"
- "traefik.http.middlewares.rate-limit.ratelimit.burst=400"
- "traefik.http.middlewares.rate-limit.ratelimit.period=1m"
```

200 Requests/Minute average, Burst bis 400. Hoeher als ueblich, weil Nextcloud-Desktop-Clients bei Datei-Sync viele Requests generieren (Chunked Uploads, WebDAV-Propfinds). Collabora und Coder sind ausgenommen (WebSocket-Traffic vertraegt kein striktes Rate-Limiting). Nextcloud hat zusaetzlich eine eingebaute Brute-Force-Protection.

---

## 9. OpenProject-Nextcloud-Integration

Die offizielle Integration verknuepft Dateien aus Nextcloud direkt mit OpenProject Work Packages.

### Features

- Dateien und Ordner aus Nextcloud an Work Packages anhaengen
- Automatische Projekt-Ordner in Nextcloud erstellen lassen
- OpenProject-Benachrichtigungen im Nextcloud-Dashboard
- Work-Package-Suche in Nextcloud
- Dateien ueber OpenProject direkt in Collabora oeffnen (ueber Nextcloud)

### Einrichtung

**Schritt 1: Nextcloud-App installieren**

```bash
docker exec -u www-data nextcloud php occ app:install integration_openproject
```

**Schritt 2: OAuth in OpenProject konfigurieren**

1. OpenProject Admin -> Administration -> File Storages -> Add Storage
2. Typ: Nextcloud
3. Name: Nextcloud (frei waehlbar)
4. Host: `https://cloud.example.de`
5. OAuth-Credentials werden generiert — diese in Nextcloud eintragen

**Schritt 3: OAuth in Nextcloud konfigurieren**

1. Nextcloud Admin -> Einstellungen -> Verwaltung -> OpenProject Integration
2. OpenProject-URL: `https://openproject.example.de`
3. OAuth Client ID und Secret aus Schritt 2 eintragen
4. Nextcloud generiert eigene OAuth-Credentials zurueck -> in OpenProject eintragen

**Schritt 4: Storage in OpenProject-Projekt aktivieren**

1. OpenProject -> Projekt -> Projekteinstellungen -> Module -> "File Storages" aktivieren
2. Unter Projekteinstellungen -> File Storages den Nextcloud-Storage hinzufuegen
3. Optional: Automatische Projekt-Ordner aktivieren

### Voraussetzung

Beide Instanzen muessen sich gegenseitig ueber ihre oeffentlichen URLs erreichen koennen. Da beide im `proxy`-Netzwerk haengen, laeuft die Kommunikation ueber Traefik (HTTPS).

---

## 10. Nextcloud Speicher (Lokal)

Nextcloud speichert alle Dateien lokal auf dem NVMe-RAID-1 des Servers. Metadaten (Dateinamen, Ordnerstruktur) liegen in der PostgreSQL-Datenbank, die eigentlichen Dateien im `nc-data` Volume.

### Volumes

```yaml
volumes:
  - nc-html:/var/www/html
  - nc-data:/var/www/html/data
```

### Speicherplanung

| Daten | Groesse (initial) | Wachstum |
|-------|-------------------|----------|
| Nextcloud-Installation (`nc-html`) | ~1 GB | Gering (nur bei NC-Updates) |
| Nutzer-Dateien (`nc-data`) | ~0 GB | Abhaengig von Nutzung |
| **Verfuegbar (RAID-1)** | **~480 GB** | |

Bei 1-5 Personen in einer IT-Beratung (Office-Dokumente, PDFs, Praesentationen) sind 50-100 GB im ersten Jahr realistisch. ~480 GB RAID-1 reichen fuer mehrere Jahre.

### Spaetere Migration auf S3

Falls der lokale Speicher knapp wird, kann Nextcloud auf S3 Primary Objectstore migriert werden. Das erfordert:

1. Hetzner Object Storage Bucket anlegen
2. `OBJECTSTORE_S3_*` Environment-Variablen konfigurieren
3. Bestehende Dateien migrieren (aufwaendig, aber dokumentiert)

**Hinweis:** S3 als Primary Objectstore ist eine Einweg-Entscheidung — der Wechsel zurueck auf lokal ist nicht praktikabel. Daher starten wir bewusst mit lokalem Speicher.

### Vorteile lokaler Speicher

- **NVMe-Performance**: ~0.1ms Latenz statt ~5-20ms ueber S3/HTTPS
- **Einfacheres Setup**: Keine S3-Credentials, Bucket-Policies, SDK-Kompatibilitaet
- **`occ files:scan` funktioniert** (bei S3 Primary nicht moeglich)
- **Direkter Dateizugriff** fuer Debugging und Recovery
- **Kein Vendor-Lock-in** auf Object Storage
- **Reversibel**: Migration auf S3 jederzeit moeglich

---

## 11. Collabora Online

Collabora CODE ermoeglicht Dokumentenbearbeitung (Writer, Calc, Impress) direkt im Browser ueber Nextcloud.

### Container-Konfiguration

```yaml
collabora:
  image: collabora/code:25.04.9.3.1
  container_name: collabora
  restart: unless-stopped
  environment:
    aliasgroup1: "https://${NC_HOSTNAME}:443"
    extra_params: "--o:ssl.enable=false --o:ssl.termination=true"
    username: ${COLLABORA_ADMIN_USER:-admin}
    password: ${COLLABORA_ADMIN_PASSWORD}
    dictionaries: "de_DE en_US"
  networks:
    - proxy
  deploy:
    resources:
      limits:
        memory: 1536M
      reservations:
        memory: 1024M
  cap_add:
    - MKNOD
```

- `ssl.enable=false` + `ssl.termination=true`: TLS wird von Traefik terminiert
- `aliasgroup1`: Nur Nextcloud darf Collabora nutzen
- `dictionaries`: Deutsch und Englisch fuer Rechtschreibpruefung
- `cap_add: MKNOD`: Benoetigt fuer Collabora-interne Sandbox

### Nextcloud-Integration

1. In Nextcloud die App "Nextcloud Office" installieren:
   ```bash
   docker exec -u www-data nextcloud php occ app:install richdocuments
   ```
2. Einstellungen -> Verwaltung -> Nextcloud Office
3. "Verwende deinen eigenen Server" waehlen
4. URL: `https://office.example.de`
5. Testen ob die Verbindung funktioniert

### Nutzung ueber OpenProject

Dateien die ueber die OpenProject-Nextcloud-Integration verknuepft sind, koennen direkt in Collabora geoeffnet werden — der Klick in OpenProject oeffnet die Datei in Nextcloud, wo Collabora die Bearbeitung uebernimmt.

---

## 12. Coder Remote Development

Coder ist eine Open-Source-Plattform fuer standardisierte Remote-Entwicklungsumgebungen. Auf diesem Server laeuft nur das **Control Plane** (coderd) — die eigentlichen Workspaces werden auf externen Servern provisioniert.

### Architektur

```
+----------------------------+          +---------------------------+
| OVH RISE-S (Management)     |         | Externe Server            |
|                            |          |                           |
|  coderd (Control Plane)    | <------> | Workspace-VM (Hetzner)   |
|  + built-in Provisioner    |  Agent   | - Coder Agent             |
|  + PostgreSQL              |  conn.   | - code-server / VS Code   |
|  + Terraform (hcloud)      |          | - Dev-Tools, Repos        |
|                            |          +---------------------------+
|  coder-socket-proxy ----+  |
|    (Docker Socket Proxy) |  |
|    POST=1, read/write    |  |
|         |                |  |
|         v                |  |
|  /var/run/docker.sock    |  |
|         |                |  |
|  Lokale Docker-Container |  |
|  - Container-Workspaces  |  |
|  - Coder Agent           |  |
+----------------------------+
```

### Container-Konfiguration

```yaml
coder-db:
  image: postgres:18.3-alpine
  container_name: coder-db
  restart: unless-stopped
  environment:
    POSTGRES_DB: ${CODER_DB_NAME:-coder}
    POSTGRES_USER: ${CODER_DB_USER:-coder}
    POSTGRES_PASSWORD: ${CODER_DB_PASSWORD:?CODER_DB_PASSWORD muss gesetzt sein}
  volumes:
    - coder-pgdata:/var/lib/postgresql
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
  environment:
    CODER_PG_CONNECTION_URL: "postgresql://${CODER_DB_USER:-coder}:${CODER_DB_PASSWORD}@coder-db/${CODER_DB_NAME:-coder}?sslmode=disable"
    CODER_HTTP_ADDRESS: "0.0.0.0:7080"
    CODER_ACCESS_URL: "https://${CODER_HOSTNAME:-coder.example.de}"
    CODER_WILDCARD_ACCESS_URL: ""
    DOCKER_HOST: tcp://coder-socket-proxy:2375
    # Terraform/Hetzner fuer Workspace-Provisionierung
    HCLOUD_TOKEN: ${HCLOUD_TOKEN}
  networks:
    - proxy
    - coder-backend
    - coder-socket-proxy
  depends_on:
    coder-db:
      condition: service_healthy
    coder-socket-proxy:
      condition: service_started
  deploy:
    resources:
      limits:
        memory: 1536M
      reservations:
        memory: 768M
```

### Traefik-Labels

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.docker.network=proxy"
  # Router
  - "traefik.http.routers.coder.rule=Host(`${CODER_HOSTNAME}`)"
  - "traefik.http.routers.coder.entrypoints=websecure"
  - "traefik.http.routers.coder.tls.certresolver=letsencrypt"
  # Service
  - "traefik.http.services.coder.loadbalancer.server.port=7080"
  # Headers
  - "traefik.http.routers.coder.middlewares=coder-headers"
  - "traefik.http.middlewares.coder-headers.headers.customRequestHeaders.X-Forwarded-Proto=https"
  - "traefik.http.middlewares.coder-headers.headers.stsSeconds=31536000"
```

Kein Rate-Limiting auf Coder — WebSocket-Traffic fuer Terminal/IDE vertraegt das nicht.

### Workspace-Templates

Coder nutzt Terraform-Templates, um Workspaces zu definieren. Zwei Templates werden bereitgestellt:

**Template 1: Hetzner Cloud VM (on-demand)**

Erstellt eine dedizierte VM pro Workspace. Ideal fuer grosse Projekte oder wenn Isolation wichtig ist.

- Terraform Provider: `hetznercloud/hcloud`
- Server-Typ konfigurierbar (z.B. CX22, CX32)
- Automatisches Start/Stop (Kosten nur bei Nutzung)
- Eigenes Volume fuer persistente Daten
- Community-Referenz: `ntimo/coder-hetzner-cloud-template`

**Template 2: Docker-Container lokal auf OVH RISE-S**

Erstellt Container direkt auf dem Management-Server. Ideal fuer schnelle Tasks und leichtgewichtige Workspaces.

- Terraform Provider: `kreuzwerker/docker`
- Docker-Zugriff ueber `coder-socket-proxy` (DOCKER_HOST=tcp://coder-socket-proxy:2375)
- Geteilte Ressourcen, aber schnellster Start (kein VM-Boot)
- Keine Zusatzkosten — nutzt den vorhandenen Headroom des Dedicated Servers (64 GB RAM, ~55 GB frei)

### Workspace-Networking

**Standard: Coder DERP Relay**

Coder hat einen eingebauten DERP/STUN-Server fuer Peer-to-Peer-Verbindungen zwischen Clients und Workspaces. Funktioniert out-of-the-box, kein Extra-Setup.

**Optional: Headscale/Tailscale**

Fuer Workspaces die laenger leben oder direkten Netzwerkzugriff brauchen, kann der Coder-Agent so konfiguriert werden, dass er dem Tailnet beitritt. Dies erfordert:

1. Tailscale-Agent im Workspace-Template installieren
2. Auth-Key ueber Coder-Template-Variablen injecten
3. Headscale auf dem Management-Server muss erreichbar sein

### Ersteinrichtung

1. `https://coder.example.de` oeffnen
2. Ersten Admin-Account erstellen
3. Unter Templates -> Create Template die Hetzner-Cloud-Vorlage importieren
4. Hetzner-API-Token als Template-Variable konfigurieren
5. Ersten Workspace erstellen und testen

---

## 13. Resource Limits

Jeder Container bekommt ein hartes Memory-Limit und eine Reservation. Dies schuetzt den gesamten Server vor OOM-Situationen.

```yaml
# Beispiel in docker-compose.yml:
services:
  openproject:
    deploy:
      resources:
        limits:
          memory: 2048M
        reservations:
          memory: 1536M
```

### Vollstaendige Limits

| Container | Memory Limit | Memory Reservation | Begruendung |
|-----------|-------------|-------------------|-------------|
| `socket-proxy` | 64 MB | 32 MB | Docker Socket Proxy (HAProxy) |
| `traefik` | 256 MB | 128 MB | Reverse Proxy, TLS, Routing |
| `openproject` | 2048 MB | 1536 MB | Rails + Worker + Cron + Hocuspocus |
| `openproject-db` | 512 MB | 256 MB | PostgreSQL fuer ~5 User |
| `openproject-cache` | 192 MB | 128 MB | Memcached mit 128 MB Cache-Groesse |
| `nextcloud` | 1536 MB | 768 MB | Apache + PHP (PHP_MEMORY_LIMIT=1024M braucht Headroom fuer Apache) |
| `nextcloud-db` | 512 MB | 256 MB | PostgreSQL fuer ~5 User |
| `nextcloud-redis` | 320 MB | 128 MB | Redis mit 256 MB maxmemory |
| `nextcloud-cron` | 512 MB | 128 MB | Selbes Image, aber nur Cron-Tasks |
| `collabora` | 1536 MB | 1024 MB | LibreOffice-Engine, speicherhungrig |
| `coder-socket-proxy` | 64 MB | 32 MB | Docker Socket Proxy fuer Coder (read/write) |
| `coder` | 1536 MB | 768 MB | coderd + built-in Provisioner + Terraform |
| `coder-db` | 512 MB | 256 MB | PostgreSQL fuer Coder |
| **Gesamt** | **~9.4 GB** | **~5.3 GB** | |

Bei 64 GB Dedicated Server (OVH RISE-S) bleiben ~55 GB fuer OS, Traefik, andere Dienste und zukuenftige Erweiterungen (Jitsi, Mattermost, Whisper.cpp).

---

## 14. Sicherheit

### TLS

- Traefik terminiert TLS mit Let's Encrypt
- HSTS aktiviert (31536000 Sekunden / 1 Jahr)
- `X-Forwarded-Proto: https` auf allen Diensten

### Rate-Limiting

- Traefik Rate-Limit Middleware: 200 req/min average, 400 burst
- Auf OpenProject- und Nextcloud-Routern aktiviert
- Collabora ausgenommen (WebSocket-Traffic vertraegt kein striktes Rate-Limiting)

### Anwendungs-eigene Schutzmechanismen

- **Nextcloud**: Eingebaute Brute-Force-Protection (automatisch aktiv)
- **OpenProject**: Account-Lockout nach fehlgeschlagenen Login-Versuchen (konfigurierbar)

### Datei-Berechtigungen

```bash
chmod 600 /opt/containers/novabrands-mgmt/.env
chown ubuntu:ubuntu /opt/containers/novabrands-mgmt/.env
```

### Netzwerk-Isolation

- Backend-Netzwerke sind nicht extern erreichbar
- Datenbanken und Cache-Server sind nur aus ihrem jeweiligen Backend-Netz zugreifbar
- Nur Container mit Traefik-Labels sind von aussen erreichbar

### Docker-Socket (Pflicht)

Der Docker-Socket ist root-equivalent Access — ohne Proxy hat ein kompromittierter Container vollen Host-Zugriff. Deshalb nutzen wir **zwei getrennte Docker Socket Proxies** (`tecnativa/docker-socket-proxy`) mit unterschiedlichen Berechtigungen:

| Proxy | Nutzer | POST | Berechtigungen | Netzwerk |
|-------|--------|------|----------------|----------|
| `socket-proxy` | Traefik | Nein | CONTAINERS, NETWORKS (read-only) | `socket-proxy` (intern) |
| `coder-socket-proxy` | Coder | Ja | CONTAINERS, IMAGES, NETWORKS, VOLUMES, EXEC, INFO (read/write) | `coder-socket-proxy` (intern) |

Traefik bekommt nur Lesezugriff. Coder benoetigt Schreibzugriff fuer die Container-Provisionierung, aber keinen Zugriff auf Swarm, Services oder Secrets. Beide Proxies laufen in isolierten internen Netzwerken.

---

## 15. Monitoring-Integration

### Healthcheck-Endpoints fuer Uptime Kuma

| Dienst | URL | Erwartung |
|--------|-----|-----------|
| OpenProject | `https://openproject.example.de/health_checks/default` | HTTP 200 |
| Nextcloud | `https://cloud.example.de/status.php` | HTTP 200, JSON mit `installed: true` |
| Collabora | `https://office.example.de/hosting/discovery` | HTTP 200, XML |
| Coder | `https://coder.example.de/api/v2/buildinfo` | HTTP 200, JSON |

### Docker-Healthchecks

Alle Container haben eingebaute Healthchecks (siehe docker-compose.yml). Docker markiert Container als `unhealthy` wenn sie fehlschlagen.

### ntfy-Alerting

Uptime Kuma unterstuetzt ntfy als Notification-Channel. Konfiguration:

1. Uptime Kuma -> Settings -> Notifications -> Add -> ntfy
2. Topic-URL: `https://ntfy.example.de/monitoring` (oder aehnlich)
3. Bei jedem Monitor den Notification-Channel aktivieren

### Healthchecks.io / Eigener Healthchecks-Server

Fuer Cron-basierte Checks (Backup-Script, Nextcloud-Cron):

```bash
# Am Ende des Backup-Scripts:
curl -fsS -m 10 --retry 5 https://healthchecks.example.de/ping/<uuid>
```

---

## 16. Backup-Strategie

### Ueberblick

| Daten | Methode | Ziel | Frequenz |
|-------|---------|------|----------|
| OpenProject DB | pg_dump (Custom-Format) | Borgmatic | Taeglich |
| Nextcloud DB | pg_dump (Custom-Format) | Borgmatic | Taeglich |
| Coder DB | pg_dump (Custom-Format) | Borgmatic | Taeglich |
| OpenProject Assets | Volume-Backup | Borgmatic | Taeglich |
| Nextcloud HTML + Dateien | Volume-Backup | Borgmatic | Taeglich |
| Konfiguration | Git-Repo | Remote | Bei Aenderung |

### RPO / RTO

- **RPO** (Recovery Point Objective): < 24 Stunden
- **RTO** (Recovery Time Objective): < 4 Stunden

### Datenbank-Dump-Script

```bash
#!/usr/bin/env bash
set -euo pipefail

DUMP_DIR="/opt/containers/novabrands-mgmt/db-dumps"
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

### Borgmatic-Einbindung

```yaml
# borgmatic config
source_directories:
  - /opt/containers/novabrands-mgmt/db-dumps
  - /var/lib/docker/volumes/novabrands-mgmt_op-assets
  - /var/lib/docker/volumes/novabrands-mgmt_nc-html
  - /var/lib/docker/volumes/novabrands-mgmt_nc-data

repositories:
  - path: ssh://u<STORAGEBOX-USER>@u<STORAGEBOX-USER>.your-storagebox.de:23/./backups/novabrands-mgmt
    label: hetzner-storagebox
  # Optional: Zweites Backup-Ziel (NAS zu Hause, anderer Standort)
  # - path: ssh://backup@nas.home.lan/volume1/backups/novabrands-mgmt
  #   label: home-nas

before_backup:
  - /opt/containers/novabrands-mgmt/dump-databases.sh

after_backup:
  - curl -fsS -m 10 --retry 5 https://healthchecks.example.de/ping/<uuid>
```

**Backup-Ziel:** Hetzner StorageBox (SSH/Borg-kompatibel, Sub-Accounts moeglich). Optional ein zweites Ziel (z.B. NAS zu Hause) fuer 3-2-1-Backup-Regel.

**Hinweis:** `nc-data` enthaelt alle Nutzer-Dateien und muss im Backup enthalten sein. Bei wachsendem Datenvolumen Borgmatic-Deduplizierung nutzen (Borg dedupliziert automatisch — inkrementelle Backups sind klein).

---

## 17. Restore-Prozedur

### Vollstaendiger Restore (Worst Case: Server komplett weg)

**Geschaetzte Dauer: 2-3 Stunden**

#### Schritt 1: Server und Docker aufsetzen

```bash
# Docker + Compose installieren (falls noetig)
# Traefik deployen (falls noetig)
# DNS pruefen
```

#### Schritt 2: Stack-Verzeichnis und Konfiguration wiederherstellen

```bash
mkdir -p /opt/containers/novabrands-mgmt
cd /opt/containers/novabrands-mgmt

# Repo klonen (enthaelt docker-compose.yml und .env.template)
git clone <repo-url> .
# .env aus Proton Pass generieren
pass-cli inject --in-file .env.template --out-file .env --file-mode 0600
# htpasswd fuer Traefik nachtragen (siehe setup.sh Schritt 18)
chmod 600 .env
```

#### Schritt 3: Netzwerke und Volumes erstellen

```bash
docker network create proxy  # falls nicht vorhanden
docker compose up -d openproject-db nextcloud-db  # Nur DBs starten
sleep 10  # Warten bis DBs bereit
```

#### Schritt 4: Datenbanken wiederherstellen

```bash
# Borgmatic-Backup mounten / entpacken
# DB-Dumps nach /opt/containers/novabrands-mgmt/db-dumps/ kopieren

# OpenProject
docker cp db-dumps/openproject.dump openproject-db:/tmp/openproject.dump
docker exec openproject-db pg_restore \
  -U openproject \
  -d openproject \
  --clean --if-exists \
  /tmp/openproject.dump

# Nextcloud
docker cp db-dumps/nextcloud.dump nextcloud-db:/tmp/nextcloud.dump
docker exec nextcloud-db pg_restore \
  -U nextcloud \
  -d nextcloud \
  --clean --if-exists \
  /tmp/nextcloud.dump

# Coder
docker cp db-dumps/coder.dump coder-db:/tmp/coder.dump
docker exec coder-db pg_restore \
  -U coder \
  -d coder \
  --clean --if-exists \
  /tmp/coder.dump
```

#### Schritt 5: Volumes wiederherstellen

```bash
# OpenProject Assets aus Borgmatic-Backup in Volume kopieren
# Nextcloud HTML aus Borgmatic-Backup in Volume kopieren
# (Exakte Befehle haengen vom Borg-Mount-Pfad ab)
```

#### Schritt 6: Stack starten

```bash
docker compose up -d
```

#### Schritt 7: Validierung

```bash
# Container-Status pruefen
docker compose ps

# Healthchecks pruefen
curl -f https://openproject.example.de/health_checks/default
curl -f https://cloud.example.de/status.php
curl -f https://office.example.de/hosting/discovery
curl -f https://coder.example.de/api/v2/buildinfo

# Nextcloud Reparatur laufen lassen
docker exec -u www-data nextcloud php occ maintenance:repair
docker exec -u www-data nextcloud php occ db:add-missing-indices

# Dateisystem pruefen
docker exec -u www-data nextcloud php occ files:scan --all
docker exec -u www-data nextcloud php occ status
```

### Einzelner Container oder Dienst wiederherstellen

Bei Ausfall eines einzelnen Containers genuegt oft:

```bash
docker compose up -d <service-name>
```

Bei Datenbank-Korruption: DB-Container stoppen, Volume loeschen, neu erstellen, Dump einspielen (Schritte 3-4 fuer den betroffenen Dienst).

### Restore testen

**Empfehlung:** Restore-Prozedur einmal auf einem separaten vServer oder lokalen Docker-Setup durchspielen, bevor der Stack produktiv geht. Dokumentieren was funktioniert hat und was nachgebessert werden muss.

---

## 18. DSGVO und Compliance

### Warum relevant

Als IT-Beratung werden Kundendaten in OpenProject (Projekte, Aufgaben, Kontakte) und Nextcloud (Dokumente, Kalender) verarbeitet. Das loest DSGVO-Pflichten aus.

### Auftragsverarbeitungsvertrag (AVV)

- **OVH**: Standard-AVV abschliessen (verfuegbar unter ovhcloud.com/de/personal-data-protection/data-processing-agreement/)
- **Hetzner**: Standard-AVV abschliessen (fuer Cloud API / Coder-Workspaces und StorageBox / Backups — verfuegbar unter hetzner.com/legal/dpa)
- **SMTP-Relay**: AVV mit Proton oder SMTP2Go abschliessen

### Technische Massnahmen

| Massnahme | Umsetzung |
|-----------|-----------|
| **Verschluesselung in Transit** | TLS 1.2+ ueber Traefik (Let's Encrypt) |
| **Verschluesselung at Rest** | NVMe-Verschluesselung prufen (OVH-Konfiguration), Borgmatic-Backups verschluesselt |
| **Zugriffsprotokollierung** | Nextcloud: Audit-Log-App aktivieren; OpenProject: Built-in Audit-Log |
| **Zugriffskontrolle** | Getrennte Benutzerkonten, Rollenbasierte Berechtigungen |
| **Datensparsamkeit** | Nur notwendige Daten erheben, regelmaessig pruefen |
| **Backup-Verschluesselung** | Borgmatic mit Verschluesselung konfigurieren |

### Audit-Log aktivieren

```bash
# Nextcloud
docker exec -u www-data nextcloud php occ app:install admin_audit
docker exec -u www-data nextcloud php occ app:enable admin_audit
```

OpenProject hat Audit-Logging (Activity Stream) standardmaessig aktiviert.

### Loeschkonzept

- Kundenprojekte nach Vertragsende und Ablauf der Aufbewahrungsfrist loeschen
- Aufbewahrungsfristen dokumentieren (steuerlich relevante Dokumente: 10 Jahre)
- Nextcloud: Papierkorb automatisch nach 30 Tagen leeren (Default)
- OpenProject: Projekte archivieren oder loeschen

### Verzeichnis der Verarbeitungstaetigkeiten (VVT)

Ein VVT muss gefuehrt werden. Mindestens dokumentieren:
- Welche personenbezogenen Daten verarbeitet werden
- Zweck der Verarbeitung
- Rechtsgrundlage
- Speicherdauer
- Technische und organisatorische Massnahmen

Dies ist ein organisatorisches Dokument, das separat gefuehrt wird — nicht Teil dieses Stacks.

---

## 19. Wartung und Updates

### Image-Updates

Images sind exakt versioniert. Update-Workflow:

1. Renovate (oder manuell) erkennt neue Version
2. Release-Notes lesen — besonders bei Major-Updates
3. Backup erstellen (dump-databases.sh + Borgmatic)
4. Image-Tag in `docker-compose.yml` aendern
5. `docker compose pull && docker compose up -d`
6. Healthchecks pruefen
7. Aendern committen und pushen

### Nextcloud nach Updates

```bash
docker exec -u www-data nextcloud php occ maintenance:repair
docker exec -u www-data nextcloud php occ db:add-missing-indices
docker exec -u www-data nextcloud php occ db:convert-filecache-bigint
```

### OpenProject nach Major-Updates

```bash
# Logs pruefen — Migrationen laufen beim Start automatisch
docker compose logs -f openproject 2>&1 | grep -i "migrat"
```

### Aufraumen

```bash
docker image prune -f
```

### Log-Rotation

Docker-Logs konfigurieren (in `/etc/docker/daemon.json` falls nicht bereits gesetzt):

```json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
```

---

## 20. Nach dem Start

### 20.1 OpenProject

1. `https://openproject.example.de` oeffnen
2. Login: `admin` / `admin`
3. **Sofort Passwort aendern**
4. Administration -> E-Mail: SMTP konfigurieren
5. Administration -> File Storages: Nextcloud-Integration einrichten (siehe Abschnitt 9)

### 20.2 Nextcloud

1. `https://cloud.example.de` oeffnen
2. Login mit `NC_ADMIN_USER` / `NC_ADMIN_PASSWORD` aus `.env`
3. Einstellungen -> Verwaltung -> Grundeinstellungen:
   - Hintergrund-Aufgaben: **Cron** auswaehlen
   - E-Mail-Server konfigurieren
4. Sicherheits-Check unter Einstellungen -> Verwaltung -> Uebersicht
5. Apps installieren:
   - **Nextcloud Office** (richdocuments) -> Collabora einrichten (siehe Abschnitt 11)
   - **OpenProject Integration** (integration_openproject) -> OAuth einrichten (siehe Abschnitt 9)
   - **Admin Audit** (admin_audit) -> DSGVO-Logging
   - **Talk** (spreed) -> Chat und Videokonferenzen fuer interne Kommunikation
   - **Whiteboard** (whiteboard) -> Kollaborative Whiteboards (Excalidraw-basiert)

### 20.3 Nextcloud Talk und Whiteboard

**Nextcloud Talk** dient als initiale Loesung fuer Chat und Videokonferenzen (intern, 1-5 Personen). Kein zusaetzlicher Container noetig — Talk laeuft als Nextcloud-App.

```bash
docker exec -u www-data nextcloud php occ app:install spreed
```

Features: Gruppen-Chat, 1:1-Anrufe, Bildschirmfreigabe, Gaeste ueber Link einladen. Fuer groessere Meetings oder Kundenkonferenzen spaeter Jitsi Meet evaluieren (siehe Abschnitt 21).

**Nextcloud Whiteboard App** stellt kollaborative Whiteboards bereit (basierend auf Excalidraw):

```bash
docker exec -u www-data nextcloud php occ app:install whiteboard
```

Whiteboards werden als Dateien in Nextcloud gespeichert und koennen mit Work Packages in OpenProject verknuepft werden.

**Hinweis:** Fuer Echtzeit-Kollaboration (mehrere Benutzer gleichzeitig auf einem Whiteboard) benoetigt die App einen separaten Node.js-Backend-Server (`nextcloud-whiteboard-server`). Ohne diesen funktionieren Whiteboards nur im Einzelnutzer-Modus. Ob der Backend-Server noetig ist, haengt vom Nutzungsverhalten ab — fuer den Start reicht die Installation der App, der Backend-Server kann spaeter ergaenzt werden.

### 20.4 Nextcloud Optimierungen

```bash
docker exec -u www-data nextcloud php occ maintenance:repair
docker exec -u www-data nextcloud php occ db:add-missing-indices
docker exec -u www-data nextcloud php occ db:convert-filecache-bigint
docker exec -u www-data nextcloud php occ config:system:set default_phone_region --value="DE"
docker exec -u www-data nextcloud php occ config:system:set maintenance_window_start --type=integer --value=1
```

### 20.5 Collabora

1. `https://office.example.de/browser/dist/admin/admin.html` oeffnen (optional)
2. Login mit `COLLABORA_ADMIN_USER` / `COLLABORA_ADMIN_PASSWORD`
3. Pruefen ob Nextcloud-Verbindung funktioniert

### 20.6 Coder

1. `https://coder.example.de` oeffnen
2. Ersten Admin-Account erstellen (erster Benutzer wird automatisch Admin)
3. Unter Templates -> Create Template die Hetzner-Cloud-Vorlage importieren
4. Template testen: Workspace erstellen, SSH-Verbindung pruefen
5. Optional: Docker-Template fuer Container-Workspaces hinzufuegen

### 20.7 Restore-Test

**Vor dem produktiven Einsatz** die Restore-Prozedur (Abschnitt 17) einmal komplett durchspielen.

---

## 21. Roadmap: Zukuenftige Dienste

Diese Dienste sind nicht Teil des initialen Stacks, werden aber fuer spaeter geplant. Die Architektur (Traefik, Docker-Netzwerke, Hetzner-Infrastruktur) ist darauf vorbereitet.

### Jitsi Meet (Videokonferenzen)

**Zeitpunkt:** Wenn Nextcloud Talk fuer Kunden-Meetings oder groessere Gruppen nicht ausreicht.

Jitsi laeuft auf einem **separaten Server** (Hetzner Cloud CX22 oder aehnlich), da die WebRTC-Engine speicher- und CPU-intensiv ist und den Management-Server nicht belasten soll.

- Eigene Subdomain (z.B. `meet.example.de`)
- Deployment per Docker Compose (offizielles `jitsi/docker-jitsi-meet`)
- Gaeste-Zugang ohne Account moeglich
- Integration in Nextcloud Talk ueber Jitsi-Plugin
- Geschaetzte Kosten: ~€4-8/Monat (CX22 Cloud-VM, nur bei Bedarf)

### Mattermost (Team-Chat)

**Zeitpunkt:** Wenn Nextcloud Talk als Chat-Loesung nicht ausreicht (z.B. bei Bedarf an Channels, Thread-Konversationen, umfangreichen Integrationen).

Mattermost koennte auf dem Management-Server mitlaufen (zusaetzlicher Container + PostgreSQL-Instanz). Bei einem Dedicated Server (64 GB RAM) ist dafuer genug Headroom vorhanden.

- Eigene Subdomain (z.B. `chat.example.de`)
- PostgreSQL-Backend (eigene Instanz)
- OpenProject-Integration verfuegbar (Mattermost-Plugin)
- Resource-Limits: ~768 MB Limit, ~512 MB Reservation

### Lokale Transkription

**Zeitpunkt:** Wenn regelmaessig Meetings transkribiert werden sollen.

Zwei Optionen:

1. **CPU-basiert auf Dedicated Server**: Whisper.cpp mit deutschem Modell. Langsamer, aber keine Zusatzkosten. Nur realistisch auf einem Dedicated Server mit genuegend CPU-Headroom.
2. **Cloud-API**: OpenAI Whisper API oder vergleichbar. Schneller, aber Kosten pro Minute und Daten verlassen den eigenen Server.

Fuer den Start reichen Cloud-APIs — lokale Transkription evaluieren wenn das Volumen waechst oder Datenschutzanforderungen es erfordern.

### Authelia (SSO / Zentrale Authentifizierung)

**Zeitpunkt:** Wenn mehr als 5 User verwaltet werden, mehrere zusaetzliche Services laufen (Mattermost, Gitea, Jitsi, etc.), oder ein Kunde explizit MFA auf allen Diensten fordert.

Authelia ist ein Open-Source Auth-Proxy (Apache 2.0), der als ForwardAuth-Middleware vor Traefik sitzt. Alle Requests werden erst durch Authelia geleitet — Login-Portal, 2FA, dann Weiterleitung zum Service.

- SSO: Einmal einloggen, alle Services nutzen
- 2FA: TOTP, WebAuthn/Passkeys, Push Notifications
- OpenID Connect Provider (OIDC) — ersetzt separate OAuth-Konfigurationen
- Granulare Zugriffsregeln (User/Gruppen pro Service)
- Container unter 20 MB, RAM-Verbrauch unter 30 MB

**Warum nicht ab Tag 1:** Alle Services (OpenProject, Nextcloud, Coder) haben bereits eigene Authentifizierung mit Brute-Force-Schutz. Bei 1-5 Personen ist zentrales IAM Overhead ohne Mehrwert. Nachruestbar ohne Aenderung an den bestehenden Services (nur Traefik-Labels ergaenzen).

---

## 22. Troubleshooting

### OpenProject: ERR_SSL_PROTOCOL_ERROR

Sicherstellen dass `OPENPROJECT_HTTPS=true` und `OPENPROJECT_HSTS=true` in der OpenProject-Container-Konfiguration gesetzt sind (siehe Abschnitt 3, Komponenten) und Traefik den `X-Forwarded-Proto: https` Header setzt.

### Nextcloud: "Access through untrusted domain"

```bash
docker exec -u www-data nextcloud php occ config:system:set \
  trusted_domains 0 --value="cloud.example.de"
```

### Nextcloud: "Reverse proxy header configuration is incorrect"

`TRUSTED_PROXIES` muss die Docker-Netzwerk-Bereiche abdecken. `OVERWRITEPROTOCOL=https` muss gesetzt sein.

### Collabora: "WOPI host not allowed"

Die Domain in `aliasgroup1` muss exakt mit der Nextcloud-URL uebereinstimmen:
```
aliasgroup1: "https://cloud.example.de:443"
```

### Collabora: WebSocket-Fehler

Pruefen ob Traefik WebSocket-Traffic durchleitet. Traefik v3 macht das standardmaessig — kein separates Middleware noetig.

### OpenProject-DB-Migration haengt beim Erststart

OpenProject braucht beim ersten Start 1-3 Minuten fuer DB-Migrationen:
```bash
docker compose logs -f openproject 2>&1 | grep -i "migrat"
```

### Redis-Verbindung schlaegt fehl

```bash
docker exec nextcloud-redis redis-cli -a "$NC_REDIS_PASSWORD" ping
# Erwartet: PONG
```

### Coder: "Workspace agent is not connected"

- Pruefen ob die Workspace-VM/der Container erreichbar ist
- `CODER_ACCESS_URL` muss von den Workspaces aus erreichbar sein (oeffentliche URL)
- Firewall auf der Workspace-VM pruefen (Port 443 ausgehend muss offen sein)

### Coder: Terraform-Fehler bei Workspace-Erstellung

```bash
# Coder-Logs pruefen
docker compose logs -f coder 2>&1 | grep -i "provision"
```

- Hetzner-API-Token pruefen (`HCLOUD_TOKEN` in .env)
- Terraform-Template-Syntax validieren

### Container-Netzwerk-Probleme

```bash
docker network ls | grep proxy
docker network inspect proxy
```

---

## Anhang: Ressourcen-Abschaetzung

### RAM (64 GB Dedicated Server, OVH RISE-S)

| Komponente | Limit | Reservation |
|-----------|-------|-------------|
| Dieser Stack (gesamt) | ~9.4 GB | ~5.3 GB |
| Andere Dienste (geschaetzt) | ~1.0 GB | ~0.5 GB |
| OS + Docker Engine | ~0.5 GB | — |
| **Gesamt belegt** | **~10.9 GB** | **~5.8 GB** |
| **Frei verfuegbar** | **~53.1 GB** | |

Massiver Headroom fuer zukuenftige Dienste (Jitsi, Mattermost, Whisper.cpp) und Lastspitzen.

### Disk (OVH RISE-S, 2x 512 GB NVMe RAID-1 = ~480 GB nutzbar)

| Daten | Groesse (initial) |
|-------|-----------------|
| Docker Images (alle) | ~4 GB |
| PostgreSQL-Daten (drei DBs) | ~0.5 GB |
| OpenProject Assets | ~0.5 GB |
| Nextcloud HTML (Installation) | ~1 GB |
| Nextcloud Nutzer-Dateien | ~0 GB (wachsend) |
| DB-Dumps | ~0.5 GB |
| **Gesamt initial** | **~6.5 GB** |
| **Verfuegbar (RAID-1)** | **~480 GB** |

Nutzer-Dateien liegen lokal auf NVMe. Bei 1-5 Personen (Office-Dokumente, PDFs) sind 50-100 GB im ersten Jahr realistisch. Speicher reicht fuer mehrere Jahre. Falls noetig, koennen 2 freie NVMe-Slots bei OVH nachgeruestet werden.
