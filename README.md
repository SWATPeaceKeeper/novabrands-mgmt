# novabrands-mgmt

Documentation and management stack for Novabrands IT consulting.

## Stack

| Service | Purpose |
|---------|---------|
| **OpenProject** | Project management, tasks, Gantt, Wiki |
| **Nextcloud** | Cloud storage, CalDAV/CardDAV, file sharing |
| **Collabora** | Browser-based document editing (via Nextcloud) |
| **Coder** | Remote development environments (control plane) |
| **Traefik** | Reverse proxy, TLS termination |

Runs on an OVH RISE-S dedicated server (Frankfurt). Full specification in `SPEC.md`.

## Quick Start

```bash
# 1. Provision server
./setup.sh

# 2. Start the stack
ssh ubuntu@<SERVER_IP>
cd /opt/containers/novabrands-mgmt
docker compose up -d

# 3. Follow post-deployment steps in SPEC.md Section 20
```

## Files

| File | Description |
|------|-------------|
| `SPEC.md` | Full specification (architecture, config, security, backup) |
| `docker-compose.yml` | Docker Compose stack definition |
| `.env.template` | Environment template (secrets via Proton Pass) |
| `setup.sh` | Server provisioning script |
| `traefik/traefik.yml` | Traefik static configuration |
| `dump-databases.sh` | Backup script for all PostgreSQL databases |

## Backup

```bash
# Manual database dump
./dump-databases.sh

# Automated via Borgmatic (see SPEC.md Section 16)
```
