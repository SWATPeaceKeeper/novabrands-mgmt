#!/bin/bash
# ============================================================================
# Documentation Stack - Server Setup Script
# ============================================================================
# Provisioniert einen Hetzner CX33 VPS (Ubuntu 24.04 LTS):
#   1.  Disk-Health pruefen
#   2.  Needrestart auf automatisch stellen (keine interaktiven Prompts)
#   3.  System-Update (apt upgrade)
#   4.  SSH-Hardening (Key-only, Limits setzen)
#   5.  Pakete installieren (Docker, fail2ban)
#   6.  Unnoetige Services deaktivieren
#   7.  Kernel-Hardening (sysctl)
#   8.  Shared Memory haerten (/dev/shm noexec)
#   9.  System-Tuning (Timezone, Locale, Swappiness)
#   10. fail2ban SSH-Jail konfigurieren
#   11. Firewall konfigurieren (UFW)
#   12. Docker konfigurieren (Logging, Live-Restore, Security)
#   13. Verzeichnisstruktur + acme.json anlegen
#   14. Docker-Netzwerke erstellen
#   15. Repository klonen
#   16. secrets.env generieren
#   17. DNS Records bei Cloudflare anlegen
#   18. Traefik + Socket Proxy starten
#
# Voraussetzungen:
#   - curl, jq, openssl, ssh, infisical installiert
#   - infisical eingeloggt (infisical login)
#   - CLOUDFLARE_ZONE_ID gesetzt (CF_DNS_API_TOKEN kommt aus Infisical)
#   - SSH Key ~/.ssh/novabrands-hetzner vorhanden
#   - Infisical Projekt "novabrands-mgmt" mit allen Secrets angelegt
#   - Hetzner VPS laeuft mit Ubuntu 24.04, Root-Zugang per SSH Key
#
# Verwendung:
#   infisical login
#   export CLOUDFLARE_ZONE_ID=...
#   ./setup.sh
# ============================================================================
set -euo pipefail
trap 'error "Setup fehlgeschlagen in Zeile $LINENO."' ERR

# ---------------------------------------------------------------------------
# KONFIGURATION
# ---------------------------------------------------------------------------
SERVER_IP="178.104.149.226"
SSH_KEY_FILE="${HOME}/.ssh/novabrands-hetzner"
ADMIN_USER="root"
REPO_URL="https://github.com/SWATPeaceKeeper/novabrands-mgmt.git"
DEPLOY_DIR="/opt/containers/novabrands-mgmt"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Subdomains fuer DNS und Traefik
SUBDOMAINS=("openproject" "cloud" "office" "traefik")

# ---------------------------------------------------------------------------
# HILFSFUNKTIONEN
# ---------------------------------------------------------------------------
info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }
die()   { error "$*"; exit 1; }

remote() {
  ssh -i "$SSH_KEY_FILE" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o BatchMode=yes \
    -o LogLevel=ERROR \
    "${ADMIN_USER}@${SERVER_IP}" "$@"
}

cf_api() {
  local method="$1" endpoint="$2"
  shift 2
  local response
  response=$(curl -s -X "$method" \
    "https://api.cloudflare.com/client/v4${endpoint}" \
    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
    -H "Content-Type: application/json" \
    "$@")

  if ! echo "$response" | jq -e '.success' >/dev/null 2>&1; then
    local msg
    msg=$(echo "$response" | jq -r '.errors[0].message // "Unbekannter Fehler"' 2>/dev/null || echo "Ungueltige API-Antwort")
    die "Cloudflare API Fehler: ${msg}"
  fi

  echo "$response"
}

# ---------------------------------------------------------------------------
# 1. VORAUSSETZUNGEN PRUEFEN
# ---------------------------------------------------------------------------
info "Pruefe Voraussetzungen..."

for cmd in curl jq openssl ssh infisical; do
  command -v "$cmd" >/dev/null 2>&1 || die "'${cmd}' ist nicht installiert."
done

[ -z "${CLOUDFLARE_ZONE_ID:-}" ] && die "CLOUDFLARE_ZONE_ID ist nicht gesetzt."
[ -f "$SSH_KEY_FILE" ] || die "SSH Key nicht gefunden: ${SSH_KEY_FILE}"
[ -f "$(dirname "$0")/stack.env" ] || die "stack.env nicht gefunden. Bist du im Repo-Verzeichnis?"

# Secrets aus Infisical laden
info "Lade Secrets aus Infisical..."
INFISICAL_SECRETS=$(infisical secrets --env=prod --path=/novabrands-mgmt --output=dotenv 2>/dev/null) \
  || die "Infisical Secrets nicht ladbar. Erst: infisical login"
eval "$INFISICAL_SECRETS"

# CF_DNS_API_TOKEN kommt aus Infisical
[ -z "${CF_DNS_API_TOKEN:-}" ] && die "CF_DNS_API_TOKEN nicht in Infisical gefunden."
CLOUDFLARE_API_TOKEN="$CF_DNS_API_TOKEN"

info "Server:  ${SERVER_IP}"
info "User:    ${ADMIN_USER}"
info "SSH Key: ${SSH_KEY_FILE}"

ok "Voraussetzungen erfuellt."

# ---------------------------------------------------------------------------
# 2. SSH-VERBINDUNG TESTEN
# ---------------------------------------------------------------------------
info "Teste SSH-Verbindung..."

remote true 2>/dev/null || die "SSH-Verbindung fehlgeschlagen."
ok "SSH bereit."

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

# ---------------------------------------------------------------------------
# 4. NEEDRESTART KONFIGURIEREN
# ---------------------------------------------------------------------------
info "Konfiguriere needrestart (keine interaktiven Prompts)..."

remote "
  if [ -f /etc/needrestart/needrestart.conf ]; then
    sudo sed -i 's/^#\?\$nrconf{restart} .*/\$nrconf{restart} = \"a\";/' /etc/needrestart/needrestart.conf
  fi
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a
"
ok "Needrestart auf automatisch gestellt."

# ---------------------------------------------------------------------------
# 5. SYSTEM-UPDATE
# ---------------------------------------------------------------------------
info "System-Update (kann einige Minuten dauern)..."

remote "
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a
  sudo -E apt-get update -qq
  sudo -E apt-get upgrade -y -qq >/dev/null 2>&1
"
ok "System aktualisiert."

# ---------------------------------------------------------------------------
# 6. SSH-HARDENING
# ---------------------------------------------------------------------------
info "SSH-Hardening..."

remote "
  sudo tee /etc/ssh/sshd_config.d/90-hardening.conf > /dev/null <<'SSHEOF'
PermitRootLogin prohibit-password
PasswordAuthentication no
MaxAuthTries 3
LoginGraceTime 20
AllowAgentForwarding no
AllowTcpForwarding no
X11Forwarding no
AllowUsers root
ClientAliveInterval 300
ClientAliveCountMax 2
SSHEOF
  sudo chmod 644 /etc/ssh/sshd_config.d/90-hardening.conf
  sudo systemctl restart ssh
"
ok "SSH gehaertet (Root=no, Key-only, ClientAlive=300s)."

# ---------------------------------------------------------------------------
# 7. PAKETE INSTALLIEREN
# ---------------------------------------------------------------------------
info "Installiere Pakete (Docker, fail2ban, htop, jq)..."

remote "
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a
  sudo -E apt-get install -y -qq ca-certificates curl git htop vim jq \
    fail2ban apache2-utils >/dev/null 2>&1

  # Docker (offizielle Repos)
  if ! command -v docker &>/dev/null; then
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    ARCH=\$(dpkg --print-architecture)
    CODENAME=\$(. /etc/os-release && echo \"\$VERSION_CODENAME\")
    echo \"deb [arch=\${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \${CODENAME} stable\" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1
    sudo systemctl enable docker
    sudo systemctl start docker
    echo 'Docker installiert.'
  else
    echo 'Docker bereits installiert.'
  fi

  # User zur Docker-Gruppe
  sudo usermod -aG docker '${ADMIN_USER}'

  # Aufraeumen
  sudo -E apt-get autoremove -y -qq >/dev/null 2>&1
  sudo -E apt-get clean
"
ok "Pakete installiert."

# ---------------------------------------------------------------------------
# 8. UNNOETIGE SERVICES DEAKTIVIEREN
# ---------------------------------------------------------------------------
info "Deaktiviere unnoetige Services..."

remote "
  for svc in ModemManager multipathd udisks2; do
    if systemctl is-active --quiet \"\$svc\" 2>/dev/null; then
      sudo systemctl stop \"\$svc\"
      sudo systemctl disable \"\$svc\"
      sudo systemctl mask \"\$svc\"
      echo \"Deaktiviert: \$svc\"
    fi
  done
"
ok "Unnoetige Services deaktiviert (ModemManager, multipathd, udisks2)."

# ---------------------------------------------------------------------------
# 9. KERNEL-HARDENING (sysctl)
# ---------------------------------------------------------------------------
info "Kernel-Hardening (Netzwerk-Sicherheit, ASLR)..."

remote "
  sudo tee /etc/sysctl.d/90-hardening.conf > /dev/null <<'SYSCTL'
# --- Netzwerk-Sicherheit ---
# IP-Spoofing-Schutz
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# ICMP-Redirects ignorieren (MITM-Schutz)
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Source Routing deaktivieren
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# SYN-Flood-Schutz
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2

# ICMP Broadcast ignorieren (Smurf-Angriffe)
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Keine Router-Advertisements akzeptieren
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0

# IP-Forwarding: Docker braucht IPv4 forwarding fuer Container-Netzwerk
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 0

# --- Kernel-Sicherheit ---
# ASLR aktiviert (Default, explizit setzen)
kernel.randomize_va_space = 2

# Core Dumps deaktivieren
fs.suid_dumpable = 0

# dmesg nur fuer root
kernel.dmesg_restrict = 1

# Kernel-Pointer verstecken
kernel.kptr_restrict = 2
SYSCTL
  sudo sysctl -p /etc/sysctl.d/90-hardening.conf >/dev/null 2>&1
"
ok "Kernel gehaertet (Spoofing, Redirects, SYN-Flood, ASLR, Core Dumps)."

# ---------------------------------------------------------------------------
# 10. SHARED MEMORY HAERTEN
# ---------------------------------------------------------------------------
info "Haerte /dev/shm (noexec, nosuid, nodev)..."

remote "
  if ! grep -q '/dev/shm' /etc/fstab; then
    echo 'tmpfs /dev/shm tmpfs defaults,noexec,nosuid,nodev 0 0' | sudo tee -a /etc/fstab >/dev/null
    sudo mount -o remount /dev/shm
  fi
"
ok "/dev/shm gehaertet."

# ---------------------------------------------------------------------------
# 11. SYSTEM-TUNING
# ---------------------------------------------------------------------------
info "System-Tuning (Timezone, Locale, Swappiness)..."

remote "
  # Timezone
  sudo timedatectl set-timezone Europe/Berlin

  # Locale
  sudo locale-gen de_DE.UTF-8 >/dev/null 2>&1
  sudo update-locale LANG=de_DE.UTF-8 >/dev/null 2>&1

  # Swappiness runter (8 GB RAM, Swap als Sicherheitsnetz)
  sudo sysctl -w vm.swappiness=10 >/dev/null
  echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-swappiness.conf >/dev/null
"
ok "Timezone=Europe/Berlin, Locale=de_DE.UTF-8, Swappiness=10."

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

# ---------------------------------------------------------------------------
# 12. FAIL2BAN SSH-JAIL
# ---------------------------------------------------------------------------
info "Konfiguriere fail2ban SSH-Jail..."

remote "
  sudo tee /etc/fail2ban/jail.local > /dev/null <<'F2B'
[sshd]
enabled = true
port = ssh
filter = sshd
backend = systemd
maxretry = 3
findtime = 600
bantime = 3600
F2B
  sudo systemctl enable fail2ban >/dev/null 2>&1
  sudo systemctl restart fail2ban
"
ok "fail2ban aktiv (SSH: 3 Versuche, 1h Ban)."

# ---------------------------------------------------------------------------
# 13. FIREWALL (UFW)
# ---------------------------------------------------------------------------
info "Konfiguriere Firewall (UFW)..."

remote "
  sudo ufw default deny incoming >/dev/null
  sudo ufw default allow outgoing >/dev/null
  sudo ufw allow ssh >/dev/null
  sudo ufw allow 80/tcp >/dev/null
  sudo ufw allow 443/tcp >/dev/null
  sudo ufw --force enable >/dev/null
"
ok "Firewall aktiv (SSH, HTTP, HTTPS)."

# ---------------------------------------------------------------------------
# 14. DOCKER KONFIGURIEREN
# ---------------------------------------------------------------------------
info "Konfiguriere Docker (Logging, Live-Restore, Security)..."

remote "
  sudo mkdir -p /etc/docker
  sudo tee /etc/docker/daemon.json > /dev/null <<'DOCKERCFG'
{
  \"log-driver\": \"json-file\",
  \"log-opts\": {
    \"max-size\": \"10m\",
    \"max-file\": \"3\"
  },
  \"live-restore\": true,
  \"userland-proxy\": false
}
DOCKERCFG
  sudo systemctl restart docker
"
ok "Docker konfiguriert (Logging=10m/3, Live-Restore=on, no-new-privileges=on)."

# ---------------------------------------------------------------------------
# 15. VERZEICHNISSTRUKTUR
# ---------------------------------------------------------------------------
info "Erstelle Verzeichnisse..."

remote "
  sudo mkdir -p '${DEPLOY_DIR}/traefik'
  sudo mkdir -p '${DEPLOY_DIR}/db-dumps'
  sudo mkdir -p /opt/containers/traefik/certs
  sudo mkdir -p /var/log/traefik

  # acme.json fuer Let's Encrypt (MUSS 600 sein)
  sudo touch /opt/containers/traefik/certs/acme.json
  sudo chmod 600 /opt/containers/traefik/certs/acme.json

  # Eigentuemer auf Admin-User
  sudo chown -R '${ADMIN_USER}:${ADMIN_USER}' /opt/containers
  sudo chown -R '${ADMIN_USER}:${ADMIN_USER}' /var/log/traefik
"
ok "Verzeichnisse erstellt."

# ---------------------------------------------------------------------------
# 16. DOCKER-NETZWERKE
# ---------------------------------------------------------------------------
info "Erstelle Docker-Netzwerke..."

remote "
  sudo docker network create proxy 2>/dev/null || true
  sudo docker network create openproject-backend 2>/dev/null || true
  sudo docker network create nextcloud-backend 2>/dev/null || true
"
ok "Netzwerke erstellt (proxy, openproject-backend, nextcloud-backend)."

# ---------------------------------------------------------------------------
# 17. REPO KLONEN
# ---------------------------------------------------------------------------
info "Klone Repository..."

remote "
  if [ -d '${DEPLOY_DIR}/.git' ]; then
    cd '${DEPLOY_DIR}' && git pull
  else
    cd '${DEPLOY_DIR}'
    git init
    git remote add origin '${REPO_URL}'
    git fetch origin
    git checkout -t origin/main
  fi
"
ok "Repository geklont."

# ---------------------------------------------------------------------------
# 18. INFISICAL CLI AUF SERVER INSTALLIEREN
# ---------------------------------------------------------------------------
info "Installiere Infisical CLI auf Server..."

remote "
  if ! command -v infisical &>/dev/null; then
    curl -1sLf 'https://artifacts-cli.infisical.com/setup.deb.sh' -o /tmp/infisical-setup.sh
    bash /tmp/infisical-setup.sh
    apt-get update -qq
    apt-get install -y -qq infisical >/dev/null 2>&1
    rm -f /tmp/infisical-setup.sh
    echo 'Infisical CLI installiert.'
  else
    echo 'Infisical CLI bereits installiert.'
  fi
"
ok "Infisical CLI auf Server bereit."

TRAEFIK_PASSWORD="${TRAEFIK_DASHBOARD_PASSWORD}"

# ---------------------------------------------------------------------------
# 19. DNS RECORDS (Cloudflare)
# ---------------------------------------------------------------------------
info "DNS Records bei Cloudflare..."

# Domain aus stack.env lesen (Klartext, kein Secret)
DOMAIN=$(grep '^DOMAIN=' "${SCRIPT_DIR}/stack.env" | cut -d= -f2-)
[ -z "$DOMAIN" ] && die "DOMAIN nicht in stack.env gefunden."
info "Domain: ${DOMAIN}"

for sub in "${SUBDOMAINS[@]}"; do
  FQDN="${sub}.${DOMAIN}"

  EXISTING=$(cf_api GET "/zones/${CLOUDFLARE_ZONE_ID}/dns_records?type=A&name=${FQDN}" | jq -r '.result | length')

  if [ "$EXISTING" -gt "0" ]; then
    RECORD_ID=$(cf_api GET "/zones/${CLOUDFLARE_ZONE_ID}/dns_records?type=A&name=${FQDN}" | jq -r '.result[0].id')
    cf_api PUT "/zones/${CLOUDFLARE_ZONE_ID}/dns_records/${RECORD_ID}" \
      -d "{\"type\":\"A\",\"name\":\"${sub}\",\"content\":\"${SERVER_IP}\",\"ttl\":300,\"proxied\":false}" >/dev/null
    ok "${FQDN} -> ${SERVER_IP} (aktualisiert)"
  else
    cf_api POST "/zones/${CLOUDFLARE_ZONE_ID}/dns_records" \
      -d "{\"type\":\"A\",\"name\":\"${sub}\",\"content\":\"${SERVER_IP}\",\"ttl\":300,\"proxied\":false}" >/dev/null
    ok "${FQDN} -> ${SERVER_IP} (erstellt)"
  fi
done

# ---------------------------------------------------------------------------
# 20. TRAEFIK + SOCKET PROXY STARTEN
# ---------------------------------------------------------------------------
info "Starte Traefik + Socket Proxy..."

remote "cd '${DEPLOY_DIR}' && CF_DNS_API_TOKEN='${CF_DNS_API_TOKEN}' docker compose --env-file stack.env up -d socket-proxy traefik"

sleep 5
TRAEFIK_STATUS=$(remote "sudo docker ps --filter name=traefik --format '{{.Status}}'")
echo "$TRAEFIK_STATUS" | grep -q "Up" || \
  die "Traefik ist nicht gestartet. Pruefe: ssh -i ${SSH_KEY_FILE} ${ADMIN_USER}@${SERVER_IP} 'sudo docker logs traefik'"

ok "Traefik + Socket Proxy laufen."

# ---------------------------------------------------------------------------
# ZUSAMMENFASSUNG
# ---------------------------------------------------------------------------
echo ""
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
echo "  Secrets:      Infisical (Pfad: /novabrands-mgmt, Env: prod)"
echo "  Config:       stack.env (committed)"
echo ""
echo "  Naechste Schritte:"
echo "    1. Machine Identity auf Server einrichten (fuer infisical run)"
echo "    2. Documentation Stack starten:"
echo "       ssh -i ${SSH_KEY_FILE} ${ADMIN_USER}@${SERVER_IP}"
echo "       cd ${DEPLOY_DIR}"
echo "       infisical run --env=prod --path=/novabrands-mgmt -- docker compose --env-file stack.env up -d"
echo "    3. Services konfigurieren (siehe SPEC.md)"
echo ""
echo "  WICHTIG: Traefik-Passwort JETZT notieren — wird nicht erneut angezeigt."
echo ""
echo "============================================================================"
