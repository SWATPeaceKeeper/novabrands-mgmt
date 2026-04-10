# Server-Migration: OVH RISE-S → Hetzner CX33

## Kontext

Der OVH RISE-S Dedicated Server (Ryzen 9700X, 64 GB RAM, Frankfurt) ist
ueberdimensioniert fuer den aktuellen Bedarf. Die Migration auf einen Hetzner
CX33 VPS (4 vCPU shared, 8 GB RAM, 80 GB SSD) reduziert die Kosten bei
ausreichender Leistung fuer den reduzierten Service-Stack.

## Scope

### Zu migrieren

| Service | Image | Volumes |
|---------|-------|---------|
| Traefik + Socket Proxy | traefik:v3.6.9, tecnativa/docker-socket-proxy:0.3.0 | TLS-Certs, Logs |
| OpenProject | openproject/openproject:17.2.1 | `op-assets` (~1 MB), `op-pgdata` (~88 MB) |
| OpenProject DB | postgres:18.3-alpine | (in op-pgdata) |
| OpenProject Cache | memcached:1.6.41-alpine | (stateless) |
| Nextcloud | nextcloud:32.0.6-apache | `nc-html` (~894 MB), `nc-data` (~131 MB) |
| Nextcloud DB | postgres:18.3-alpine | `nc-pgdata` (~77 MB) |
| Nextcloud Redis | redis:7.4.8-alpine | (stateless) |
| Nextcloud Cron | nextcloud:32.0.6-apache | (shared mit nc-html, nc-data) |
| Collabora Online | collabora/code:25.04.9.3.1 | (stateless) |

**Gesamte Datenmenge:** ~1.2 GB

### Nicht im Scope

- Coder (wird spaeter separat evaluiert)
- Speakr + WhisperX ASR (nicht mehr benoetigt)
- Coder-Workspace-Migration auf Raspberry Pi (separates Projekt)

## Server-Details

| | OVH (alt) | Hetzner (neu) |
|--|-----------|---------------|
| Typ | RISE-S Dedicated | CX33 VPS |
| CPU | Ryzen 7 9700X | 4 vCPU (shared) |
| RAM | 64 GB | 8 GB |
| Disk | 2x NVMe RAID-1 | 80 GB SSD |
| IP | 51.77.84.41 | 178.104.149.226 |
| Standort | Frankfurt | (Hetzner DC) |
| OS | Ubuntu 24.04 LTS | Ubuntu (dist-upgrade done) |

## Anpassungen

### setup.sh

Das bestehende `setup.sh` wird fuer Hetzner angepasst:

| Aenderung | Grund |
|-----------|-------|
| `SERVER_IP` → `178.104.149.226` | Neue IP |
| `ADMIN_USER` pruefen (root vs ubuntu) | Hetzner VPS Default kann root sein |
| RAID-Check entfernen (Schritt 3) | VPS hat kein RAID |
| Subdomains reduzieren | Kein `coder` Subdomain |
| Swappiness-Kommentar anpassen | 8 GB statt 64 GB |
| Swap-File anlegen (2 GB) | Sicherheitsnetz bei 8 GB RAM |

### docker-compose.yml

Reduzierter Stack mit angepassten Memory-Limits:

| Service | Limit (alt) | Limit (neu) | Reservation (neu) |
|---------|-------------|-------------|-------------------|
| Socket Proxy | 64 MB | 64 MB | 32 MB |
| Traefik | 256 MB | 256 MB | 128 MB |
| OpenProject | 2048 MB | 1536 MB | 1024 MB |
| OpenProject DB | 512 MB | 384 MB | 192 MB |
| Memcached | 192 MB | 192 MB | 128 MB |
| Nextcloud | 1536 MB | 1024 MB | 512 MB |
| Nextcloud DB | 512 MB | 384 MB | 192 MB |
| Redis | 320 MB | 256 MB | 128 MB |
| Nextcloud Cron | 512 MB | 384 MB | 128 MB |
| Collabora | 1536 MB | 1024 MB | 512 MB |
| **Gesamt** | **~7.5 GB** | **~5.5 GB** | **~3.0 GB** |

Verbleibend fuer OS + Docker: ~2.5 GB

Entfernt werden:
- `coder-socket-proxy` Service + Netzwerk
- `coder-db` Service
- `coder` Service
- `speakr-asr` Service
- `speakr` Service
- `coder-pgdata`, `speakr-uploads`, `speakr-instance`, `speakr-asr-cache` Volumes
- `coder-backend`, `speakr-backend` Netzwerke

### .env.template

Entfernt:
- `CODER_HOSTNAME`, `CODER_DB_*`, `CODER_EXTERNAL_AUTH_*`
- `SPEAKR_HOSTNAME`, `SPEAKR_ADMIN_*`, `SPEAKR_HF_TOKEN`
- `HCLOUD_TOKEN` (erstmal nicht benoetigt)

### Archivierung

Alte OVH-Configs werden nach `archive/ovh/` verschoben:
- `archive/ovh/docker-compose.yml`
- `archive/ovh/setup.sh`
- `archive/ovh/dump-databases.sh`
- `archive/ovh/.env.template`
- `archive/ovh/traefik/traefik.yml`

## Migrationsablauf

### Phase 1 — Neuen Server vorbereiten (keine Downtime)

1. Alte Configs nach `archive/ovh/` kopieren
2. `setup.sh` fuer Hetzner anpassen
3. `docker-compose.yml` anpassen (reduzierter Stack, Memory-Limits)
4. `.env.template` anpassen (Coder/Speakr Variablen raus)
5. Aenderungen committen und pushen
6. `setup.sh` ausfuehren (Server gehaertet, Docker bereit, Traefik laeuft)
7. Swap-File anlegen: `fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile`
8. In `/etc/fstab` eintragen: `/swapfile swap swap defaults 0 0`

### Phase 2 — Daten migrieren (Downtime beginnt)

9. OVH: Nextcloud Maintenance Mode aktivieren:
   `docker exec -u www-data nextcloud php occ maintenance:mode --on`
10. OVH: Datenbank-Dumps erstellen (angepasstes `dump-databases.sh`, ohne Coder):
    ```
    docker exec openproject-db pg_dump -U openproject -d openproject --format=custom -f /tmp/openproject.dump
    docker exec nextcloud-db pg_dump -U nextcloud -d nextcloud --format=custom -f /tmp/nextcloud.dump
    ```
11. OVH: Dumps + Volume-Daten aus Containern holen:
    ```
    docker cp openproject-db:/tmp/openproject.dump ./db-dumps/
    docker cp nextcloud-db:/tmp/nextcloud.dump ./db-dumps/
    ```
12. OVH: Alle Services stoppen: `docker compose down`
13. OVH: Volume-Daten exportieren:
    ```
    docker run --rm -v novabrands-mgmt_nc-html:/data -v $(pwd)/export:/export alpine tar czf /export/nc-html.tar.gz -C /data .
    docker run --rm -v novabrands-mgmt_nc-data:/data -v $(pwd)/export:/export alpine tar czf /export/nc-data.tar.gz -C /data .
    docker run --rm -v novabrands-mgmt_op-assets:/data -v $(pwd)/export:/export alpine tar czf /export/op-assets.tar.gz -C /data .
    ```
14. OVH → Hetzner: Daten transferieren:
    ```
    rsync -avz ./db-dumps/ ./export/ ubuntu@178.104.149.226:/opt/containers/novabrands-mgmt/migration/
    ```

### Phase 3 — Auf Hetzner starten

15. Hetzner: PostgreSQL-Container starten (nur DBs):
    `docker compose up -d openproject-db nextcloud-db`
16. Hetzner: Datenbanken restoren:
    ```
    docker cp migration/openproject.dump openproject-db:/tmp/
    docker exec openproject-db pg_restore -U openproject -d openproject --clean --if-exists /tmp/openproject.dump
    docker cp migration/nextcloud.dump nextcloud-db:/tmp/
    docker exec nextcloud-db pg_restore -U nextcloud -d nextcloud --clean --if-exists /tmp/nextcloud.dump
    ```
17. Hetzner: Volume-Daten importieren:
    ```
    docker run --rm -v novabrands-mgmt_nc-html:/data -v $(pwd)/migration:/import alpine sh -c "tar xzf /import/nc-html.tar.gz -C /data"
    docker run --rm -v novabrands-mgmt_nc-data:/data -v $(pwd)/migration:/import alpine sh -c "tar xzf /import/nc-data.tar.gz -C /data"
    docker run --rm -v novabrands-mgmt_op-assets:/data -v $(pwd)/migration:/import alpine sh -c "tar xzf /import/op-assets.tar.gz -C /data"
    ```
18. Hetzner: Alle Services starten: `docker compose up -d`
19. Hetzner: Healthchecks abwarten und Smoke-Tests:
    - OpenProject: Login, Projekt oeffnen
    - Nextcloud: Login, Datei oeffnen
    - Collabora: Dokument im Browser bearbeiten
20. Hetzner: Nextcloud Maintenance Mode deaktivieren:
    `docker exec -u www-data nextcloud php occ maintenance:mode --off`

### Phase 4 — DNS-Switch

21. Cloudflare: A-Records auf `178.104.149.226` umbiegen (via `setup.sh` Schritt 19 oder manuell)
22. Traefik: Holt sich automatisch neue Let's Encrypt Zertifikate
23. Nextcloud: `trusted_domains` pruefen (bleibt gleich, nur IP aendert sich hinter den Kulissen)
24. Warten bis DNS propagiert (TTL 300s = 5 Minuten)

### Phase 5 — Aufraumen

25. OVH-Server noch 3-5 Tage als Fallback stehen lassen
26. Taeglicher Check: Kommen noch Requests auf der alten IP an?
27. Wenn stabil: OVH kuendigen
28. `migration/` Verzeichnis auf Hetzner loeschen

## Rollback-Plan

Falls auf Hetzner etwas nicht funktioniert:

1. DNS-Records zurueck auf `51.77.84.41` setzen (5 Min TTL)
2. OVH: `docker compose up -d` — alter Stack startet wieder
3. Problem auf Hetzner in Ruhe debuggen

## Offene Punkte

- Hetzner Admin-User pruefen (root vs ubuntu) — bestimmt SSH-Config in setup.sh
- SSH-Key fuer Hetzner-Server einrichten (`~/.ssh/config` Eintrag)
- SMTP-Konfiguration: gleicher Provider, funktioniert unabhaengig vom Server
- Nextcloud `config.php`: `trusted_domains` und `overwrite.cli.url` pruefen nach Migration
