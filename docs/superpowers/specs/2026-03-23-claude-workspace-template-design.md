# Coder Template: claude-workspace — Design Spec

**Datum:** 2026-03-23
**Status:** Approved
**Pfad:** `coder/templates/claude-workspace/`

---

## 1. Ziel

Ein Coder-Template fuer lokale Docker-Workspaces auf dem OVH RISE-S Server,
optimiert fuer Claude Code Entwicklungsumgebungen. Unterstuetzt persistente
Dev-Maschinen, kurzlebige Tasks und saubere Workspaces ueber konfigurierbare
Presets.

## 2. Architektur

```
Coder Template (Terraform)
  Parameters: system_prompt, setup_script, container_image,
              dotfiles_repo (optional), preview_port,
              mem_limit_gb, cpu_cores
  Modules:    claude-code (Tasks), code-server (VS Code)
  Resources:  coder_ai_task, docker_container, docker_volume
  Presets:    Dev Machine, DevOps Task, Clean

Docker Container (codercom/example-universal:ubuntu)
  Template-Tools (setup.sh):
    rg, fd, jq, shellcheck, shfmt, tmux,
    uv, ruff, gh, terraform, kubectl, helm
  Personal Configs (dotfiles_repo, optional):
    CLAUDE.md, settings.json, statusline.sh,
    tmux.conf, bashrc, ...
  /home/coder  <- Docker Volume (persistent)
    projects/  <- Working directory
```

### Datenfluss

1. Nutzer erstellt Workspace (waehlt Preset oder setzt Parameter manuell)
2. Terraform provisioniert Docker Container + Volume via coder-socket-proxy
3. Coder Agent startet im Container
4. setup.sh installiert Tools (idempotent, Marker-File mit Script-Hash)
5. Dotfiles-Repo wird geklont + bootstrap.sh ausgefuehrt (wenn angegeben)
6. Claude Code Modul installiert Claude Code und startet Agent
7. Nutzer verbindet sich per SSH, VS Code oder Claude Code Integration

### Netzwerk

Der Workspace-Container laeuft auf dem OVH RISE-S Server. Coder erreicht
den Docker-Daemon ueber den `coder-socket-proxy` (read/write, POST=1).
Workspace-Container sind ueber Coders DERP Relay von aussen erreichbar.

**Docker Provider:** Der `kreuzwerker/docker` Provider erbt `DOCKER_HOST`
aus der Coder-Container-Umgebung (docker-compose.yml setzt
`DOCKER_HOST: tcp://coder-socket-proxy:2375`). Im Template wird kein
expliziter `host` im Provider-Block gesetzt — das wuerde den geerbten
Wert ueberschreiben.

**Container-Netzwerk:** Workspace-Container nutzen Dockers Default Bridge
Network fuer ausgehenden Internetzugang (apt, git clone, pip install).
Kein Anschluss an das `proxy`-Netzwerk — Workspaces sind nicht direkt
ueber Traefik erreichbar, sondern nur ueber Coders DERP Relay.

**DNS:** Standard Docker DNS (127.0.0.11) — funktioniert out-of-the-box
solange der Host DNS-Aufloesung hat.

### Beziehung zu SPEC.md

Dieses Template ist "Template 2: Docker-Container lokal auf OVH RISE-S"
aus SPEC.md Abschnitt 12. Template 1 (Hetzner Cloud VM) ist ein separates
Template und nicht Teil dieses Designs.

## 3. Komponenten

### 3.1 Terraform Template (main.tf)

**Provider:**
- `coder/coder` >= 2.13
- `kreuzwerker/docker`

**Module (Coder Registry):**
- `claude-code` v4.8.1+ — Claude Code + Tasks-Integration
- `code-server` ~> 1.0 — VS Code im Browser

**Entfernt gegenueber Original-Template:**
- Windsurf, Cursor, JetBrains Module (Fokus: Claude Code + SSH + VS Code)

**Beibehalten:**
- Preview App (coder_app, konfigurierbarer Port)
- `coder_ai_task` Resource — ermoeglicht Coders Tasks-Feature: Nutzer koennen
  ueber die Coder-UI Tasks an Claude Code delegieren, Claude arbeitet
  selbststaendig und reportet Fortschritt zurueck
- Docker Volume fuer /home/coder (persistent)
- Agent Metadata (CPU, RAM, Disk, Host-Stats)

### 3.2 Setup Script (setup.sh)

Externe Datei, referenziert via `file("setup.sh")` im Template.
Idempotent via Marker-File `$HOME/.coder-tools-v<hash>` wobei `<hash>`
die ersten 8 Zeichen des SHA256 von setup.sh ist. Aendert sich das Script,
wird der Marker ungueltig und Tools werden neu installiert.

**Zwei Phasen:**

| Phase | Wann | Was |
|-------|------|-----|
| Tool-Install | Nur beim Erststart (Marker) | apt packages, binaries, uv, ruff, gh, terraform, kubectl, helm |
| Dotfiles | Bei jedem Start | git pull + bootstrap.sh (wenn Repo angegeben) |

**Tools installiert via setup.sh:**

| Kategorie | Tools | Installationsmethode |
|-----------|-------|---------------------|
| Shell | ripgrep, fd-find, jq, shellcheck, tmux | apt |
| Shell | shfmt | GitHub Release (Go binary) |
| Python | uv | Official installer (astral.sh) |
| Python | ruff | uv tool install |
| Git | gh (GitHub CLI) | apt (official repo) |
| IaC | terraform | HashiCorp Release (zip) |
| K8s | kubectl | dl.k8s.io Release |
| K8s | helm | Official install script |

**Bereits im Base-Image (codercom/example-universal:ubuntu):**
Node.js, Python 3, Go, Rust, Java, Ruby, Docker CLI, git, curl,
vim, nano, sudo, build-essential.

### 3.3 Dotfiles Integration

- Parameter `dotfiles_repo` (string, optional, default leer)
- Leer = Clean Workspace, keine persoenlichen Configs
- Wenn gesetzt: `git clone` beim Erststart, `git pull --ff-only` bei jedem Start
- Wenn `bootstrap.sh` im Repo existiert und ausfuehrbar ist: wird ausgefuehrt
- Kompatibel mit dem bestehenden `claude-pi` Repo (angepasst fuer x86)
- Jeder Nutzer kann sein eigenes Dotfiles-Repo mitgeben

## 4. Parameter

| Parameter | Typ | Default | Mutable | Beschreibung |
|-----------|-----|---------|---------|-------------|
| system_prompt | string/textarea | "" (leer, Presets ueberschreiben) | nein | System-Prompt fuer Claude Code |
| setup_script | string/textarea | Inhalt von setup.sh via file() | nein | Post-Install-Script (Presets setzen den Inhalt) |
| container_image | string | codercom/example-universal:ubuntu | nein | Base-Image |
| dotfiles_repo | string | "" (leer = clean) | nein | Git-URL zum Dotfiles-Repo |
| preview_port | number | 8080 | ja | Port fuer die Preview-App |
| mem_limit_gb | number | 8 | nein | RAM-Limit in GB (Hard Limit, Bytes intern) |
| cpu_weight | number | 4 | nein | Relative CPU-Prioritaet (Faktor fuer cpu_shares) |

## 5. Presets

### 5.1 Dev Machine (Default)

Permanenter Workspace. Volles Ressourcen-Budget, kein System-Prompt.
Claude Code nutzt CLAUDE.md aus dem Dotfiles-Repo und Projekt-Repos.

| Parameter | Wert |
|-----------|------|
| system_prompt | "" (leer) |
| container_image | codercom/example-universal:ubuntu |
| dotfiles_repo | "" (User waehlt) |
| preview_port | 8080 |
| mem_limit_gb | 16 |
| cpu_weight | 8 |

### 5.2 DevOps Task

Fuer kurzlebige Tasks ueber Coders Tasks-Feature.
Claude bekommt Kontext ueber Umgebung und Arbeitsweise.

| Parameter | Wert |
|-----------|------|
| system_prompt | DevOps/Cloud Engineer Kontext (Umgebung, Tools, Guidelines) |
| container_image | codercom/example-universal:ubuntu |
| dotfiles_repo | "" (User waehlt) |
| preview_port | 8080 |
| mem_limit_gb | 8 |
| cpu_weight | 4 |

**System-Prompt Inhalt:**
- Framing: DevOps/Cloud engineer assistant in Coder Workspace
- Environment: Linux x86_64, OVH RISE-S, verfuegbare Tools
- Guidelines: CLAUDE.md folgen, Conventional Commits, keine Secrets hardcoden,
  deutsche Antworten, englischer Code

### 5.3 Clean Workspace

Minimale Umgebung fuer Experimente, Tests oder neue Nutzer.

| Parameter | Wert |
|-----------|------|
| system_prompt | "" (leer) |
| container_image | codercom/example-universal:ubuntu |
| dotfiles_repo | "" (leer) |
| preview_port | 8080 |
| mem_limit_gb | 4 |
| cpu_weight | 2 |

## 6. Resource Limits

### Container-Limits

```hcl
resource "docker_container" "workspace" {
  # memory erwartet Bytes (kreuzwerker/docker Provider)
  memory = data.coder_parameter.mem_limit_gb.value * 1024 * 1024 * 1024

  # Hartes CPU-Limit via CFS quota (1 core = 100000 microseconds)
  cpu_shares = 1024  # Default-Prioritaet
  # Alternativ: cpuset fuer Core-Pinning falls noetig
}
```

**Hinweis zu CPU-Limiting:** `cpu_shares` ist ein relatives Gewicht (kein
hartes Limit). Ein Container mit 4096 shares bekommt 4x mehr CPU-Zeit als
einer mit 1024 — kann aber trotzdem alle Cores nutzen wenn sonst niemand
Last erzeugt. Fuer den Anfang reicht `cpu_shares` da selten mehr als 1-2
Workspaces parallel laufen. Falls ein Workspace den Management-Stack
aushungert, kann `cpuset_cpus` (z.B. `"0-3"`) als hartes Pinning
nachgeruestet werden.

### Kapazitaetsplanung

| Ressource | Verfuegbar | Dev Machine | DevOps Task | Clean | Max parallel (gemischt) |
|-----------|-----------|-------------|-------------|-------|------------------------|
| RAM | ~53 GB frei | 16 GB | 8 GB | 4 GB | 2-3 Dev + 1-2 Tasks |
| CPU | 8C/16T | Shared | Shared | Shared | Soft-limited via shares |
| Disk | ~470 GB | ~10 GB/Vol | ~5 GB/Vol | ~3 GB/Vol | Viele |

## 7. Authentifizierung

### Claude Code

OAuth Login via `claude login`. Token persistiert in `~/.claude/` auf dem
Volume. Kein API-Key noetig (Claude Max/Pro Abo).

### GitHub

Coder External Auth mit GitHub OAuth (Server-Level Konfiguration).
Workspaces bekommen automatisch Zugriff auf Repos des authentifizierten
GitHub-Accounts.

### Git Identity

Automatisch aus Coder-Account (env vars GIT_AUTHOR_NAME, GIT_AUTHOR_EMAIL,
GIT_COMMITTER_NAME, GIT_COMMITTER_EMAIL).

## 8. Dateistruktur

```
coder/templates/claude-workspace/
  main.tf      # Terraform Template
  setup.sh     # Tool-Installation (idempotent)
  README.md    # Template-Doku fuer Coder-Nutzer
```

## 9. Betrieb

### Image Pre-Pull

`codercom/example-universal:ubuntu` ist mehrere GB gross. Vor dem ersten
Workspace-Erstellen auf dem Server vorziehen:
```bash
docker pull codercom/example-universal:ubuntu
```

### Workspace Lifecycle

Coder unterstuetzt Auto-Stop und Inactivity-TTL auf Template-Ebene.
Empfehlung:
- **Dev Machine:** Kein Auto-Delete, Auto-Stop nach 2h Inaktivitaet
- **DevOps Task:** Auto-Stop nach 1h, Auto-Delete nach 7 Tagen
- **Clean:** Auto-Stop nach 30min, Auto-Delete nach 24h

Diese Werte werden in der Coder-UI pro Template konfiguriert, nicht im
Terraform-Template selbst.

---

## 10. Phase 2 (geplant)

Autonome Agent-Presets: Task-fokussierte Workspaces die ohne Rueckfragen
arbeiten, nachdem ein Auftrag erteilt wird. Aehnlich spezialisierten Agents
mit eigenem Fokus (z.B. Code Review Agent, Security Audit Agent,
Dokumentations-Agent). Erfordert `permission_mode = "auto"` im Claude Code
Modul und spezifische System-Prompts pro Agent-Typ.
