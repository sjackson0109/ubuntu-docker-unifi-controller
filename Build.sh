#!/usr/bin/env bash
# UniFi Network Application + MongoDB 4.4 + Caddy reverse proxy (DNS-01 via Route53)
# Target host: Ubuntu 24.04 (Noble)
# Docker data-root: /srv/docker  (mountpoint on a dedicated 20 GB disk)
# UniFi data:       /srv/docker/unifi
#
# Notes:
# - This script prepares Docker, writes a Compose stack for UniFi + MongoDB, and writes a hardened Caddyfile.
# - The Caddyfile uses the route53 DNS plugin with AWS credentials provided via environment variables.
# - Ensure your Caddy build includes the 'caddy-dns/route53' plugin. The stock caddy image does not include it.
# - The UniFi service is exposed on the standard ports; adjust firewall rules as required.
#
# Usage:
#   sudo bash unifi_setup.sh
#
# After running:
#   • Deploy or reload your Caddy instance with the generated Caddyfile at /srv/docker/unifi/Caddyfile.
#   • Bring up the UniFi stack with:  docker compose -f /srv/docker/unifi/docker-compose.yml up -d
#   • Ensure DNS for the chosen $DOMAIN points to your Caddy endpoint.

set -Eeuo pipefail

# -----------------------------
# Configurable variables
# -----------------------------
DOCKER_DATA_ROOT="/srv/docker"
UNIFI_DIR="/srv/docker/unifi"
DOMAIN="${DOMAIN:-unifi.yourdomain.com}"        # export DOMAIN before running or edit here
EMAIL="${EMAIL:-admin@example.com}"             # ACME email for contact; used by some CAs if needed
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

# AWS for Caddy DNS-01 (Route53). Export these before running or place in your environment for Caddy to read.
AWS_ACCESS_KEY="${AWS_ACCESS_KEY:-}"
AWS_SECRET="${AWS_SECRET:-}"
AWS_REGION="${AWS_REGION:-}"

# -----------------------------
# Helper
# -----------------------------
need() { command -v "$1" >/dev/null 2>&1 || { echo "Error: '$1' is required." >&2; exit 1; }; }

# -----------------------------
# 1) Prepare Docker Engine with data-root=/srv/docker
# -----------------------------
echo "[1/4] Installing Docker Engine and Compose plugin, and setting data-root to ${DOCKER_DATA_ROOT}..."

need curl
need sudo
sudo apt-get update -y
sudo apt-get install -y ca-certificates curl gnupg lsb-release

sudo install -m 0755 -d /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/docker.asc ]; then
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
fi

UBU_CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME}")"
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${UBU_CODENAME} stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

sudo apt-get update -y
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Ensure mountpoint exists and is usable
sudo mkdir -p "${DOCKER_DATA_ROOT}"
sudo chown root:root "${DOCKER_DATA_ROOT}"
sudo chmod 711 "${DOCKER_DATA_ROOT}"

# Configure data-root
sudo mkdir -p /etc/docker
if [ -f /etc/docker/daemon.json ]; then
  if grep -q '"data-root"' /etc/docker/daemon.json; then
    sudo sed -i 's#"data-root":[^,}]*#"data-root": "/srv/docker"#' /etc/docker/daemon.json
  else
    # Insert before closing brace, or create fresh if malformed
    if grep -q '}' /etc/docker/daemon.json; then
      sudo awk '
        BEGIN{added=0}
        /}/ && !added { gsub(/}/,",\n  \"data-root\": \"/srv/docker\"\n}"); added=1 }
        { print }
        END{ if(!added) print "{\n  \"data-root\": \"/srv/docker\"\n}" }
      ' /etc/docker/daemon.json | sudo tee /etc/docker/daemon.json.new >/dev/null
      sudo mv /etc/docker/daemon.json.new /etc/docker/daemon.json
    else
      echo '{ "data-root": "/srv/docker" }' | sudo tee /etc/docker/daemon.json >/dev/null
    fi
  fi
else
  echo '{ "data-root": "/srv/docker" }' | sudo tee /etc/docker/daemon.json >/dev/null
fi

sudo systemctl daemon-reload
sudo systemctl enable --now docker

# -----------------------------
# 2) Generate secrets and directories for UniFi + MongoDB
# -----------------------------
echo "[2/4] Creating directories and generating credentials for UniFi + MongoDB..."

MONGO_APP_USER="unifi"
MONGO_APP_PASS="$(tr -cd 'A-Za-z0-9' </dev/urandom | fold -w 24 | head -n1)"
MONGO_ROOT_USER="root"
MONGO_ROOT_PASS="$(tr -cd 'A-Za-z0-9' </dev/urandom | fold -w 28 | head -n1)"

sudo mkdir -p "${UNIFI_DIR}/db" "${UNIFI_DIR}/data" "${UNIFI_DIR}/db-init"
sudo chown -R "${PUID}:${PGID}" "${UNIFI_DIR}/data"

# -----------------------------
# 3) Write Mongo init scripts, UniFi env, Compose, and hardened Caddyfile
# -----------------------------
echo "[3/4] Writing Mongo init scripts, UniFi env file, docker-compose.yml, and Caddyfile..."

# Mongo init: single-node replica set
cat > "${UNIFI_DIR}/db-init/01-init-rs.js" <<'JS'
try {
  rs.initiate({
    _id: "rs0",
    members: [{ _id: 0, host: "unifi-mongodb:27017" }]
  });
} catch (e) { /* replica set may already be initiated */ }
JS

# Mongo init: feature compatibility, best effort
cat > "${UNIFI_DIR}/db-init/02-fcv.js" <<'JS'
try {
  db = db.getSiblingDB("admin");
  db.adminCommand({ setFeatureCompatibilityVersion: "4.4" });
} catch (e) { /* best-effort, safe to ignore if early */ }
JS

# Mongo init: application users
cat > "${UNIFI_DIR}/db-init/03-create-users.js" <<JS
(function() {
  const appUser = "${MONGO_APP_USER}";
  const appPass = "${MONGO_APP_PASS}";
  var u = db.getSiblingDB("unifi");
  try {
    u.createUser({ user: appUser, pwd: appPass, roles: [{ role: "dbOwner", db: "unifi" }] });
  } catch (e) { /* may exist */ }
  var s = db.getSiblingDB("unifi_stat");
  try {
    s.createUser({ user: appUser, pwd: appPass, roles: [{ role: "dbOwner", db: "unifi_stat" }] });
  } catch (e) { /* may exist */ }
})();
JS

# UniFi env file
cat > "${UNIFI_DIR}/container-vars.env" <<ENV
PUID=${PUID}
PGID=${PGID}
MONGO_USER=${MONGO_APP_USER}
MONGO_PASS=${MONGO_APP_PASS}
MONGO_HOST=unifi-mongodb
MONGO_PORT=27017
MONGO_DBNAME=unifi
ENV

# Docker Compose
cat > "${UNIFI_DIR}/docker-compose.yml" <<'YML'
version: "3.8"
services:
  unifi:
    container_name: unifi
    hostname: unifi
    image: lscr.io/linuxserver/unifi-network-application:latest
    restart: unless-stopped
    networks:
      - backend
      # Attach to your external Caddy network if you proxy via Caddy:
      # - caddy_caddynet
    ports:
      - "8443:8443"        # Controller GUI/API (HTTPS)
      - "3478:3478/udp"    # STUN
      - "10001:10001/udp"  # AP/Device discovery (L2)
      - "8080:8080"        # Device inform (L3 adoption)
      - "8843:8843"        # Guest portal HTTPS (optional)
      - "8880:8880"        # Guest portal HTTP (optional)
      - "6789:6789"        # Speed test (optional)
      # - "5514:5514/udp"  # Remote syslog (optional)
    env_file:
      - container-vars.env
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - ./data:/config
    depends_on:
      unifi-mongodb:
        condition: service_healthy

  unifi-mongodb:
    container_name: unifi-mongodb
    hostname: unifi-mongodb
    image: mongo:4.4
    restart: unless-stopped
    command: ["--bind_ip_all", "--replSet", "rs0"]
    networks:
      - backend
    environment:
      MONGO_INITDB_ROOT_USERNAME: "${MONGO_ROOT_USER}"
      MONGO_INITDB_ROOT_PASSWORD: "${MONGO_ROOT_PASS}"
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - ./db:/data/db
      - ./db-init:/docker-entrypoint-initdb.d:ro
    healthcheck:
      test: ["CMD", "mongo", "--quiet", "mongodb://localhost:27017/admin", "--eval", "db.adminCommand('ping')"]
      interval: 10s
      timeout: 5s
      retries: 30

networks:
  backend:
    driver: bridge
  # caddy_caddynet:
  #   external: true
YML

# Hardened Caddyfile
# Uses Route53 DNS-01. Requires caddy built with caddy-dns/route53 and rate_limit/connection limiting plugins if you keep those directives.
cat > "${UNIFI_DIR}/Caddyfile" <<CADDY
{
  # Global options block
  acme_dns route53 {
    access_key_id "{$AWS_ACCESS_KEY}"
    secret_access_key "{$AWS_SECRET}"
    region "{$AWS_REGION}"
  }

  # Optional: global logging for Caddy itself
  # admin off
  # email ${EMAIL}
}

${DOMAIN} {
  reverse_proxy unifi:8443

  tls {
    protocols tls1.3 tls1.2
    ciphers TLS_AES_256_GCM_SHA384 TLS_CHACHA20_POLY1305_SHA256 TLS_AES_128_GCM_SHA256
    curves X25519 P-256
    alpn h2 http/1.1
  }

  header {
    Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
    X-Content-Type-Options "nosniff"
    X-Frame-Options "SAMEORIGIN"
    Referrer-Policy "no-referrer-when-downgrade"
    X-XSS-Protection "1; mode=block"
    # Permissions-Policy replaces Feature-Policy in modern browsers. Keep Feature-Policy for legacy.
    Permissions-Policy "geolocation=(), microphone=(), camera=()"
    Feature-Policy "geolocation 'none'; microphone 'none'; camera 'none'"
    -Server
  }

  log {
    output file /var/log/caddy/access.log
    format json
    level INFO
  }

  # The following directives require relevant third-party plugins:
  # - rate_limit: https://github.com/mholt/caddy-ratelimit
  # - conn_per_ip / conn_count: connection limiting plugins (there are several community modules)
  # If your Caddy does not include them, comment these blocks.
  rate_limit {
    zone default {
      key {remote}
      rate 10r/m
    }
  }

  conn_per_ip 100
  conn_count 500
}
CADDY

# -----------------------------
# 4) Final output and optional bring-up
# -----------------------------
echo "[4/4] Done. Files written under ${UNIFI_DIR}."
echo
echo "Controller URL (once Caddy is in front):  https://${DOMAIN}"
echo "UniFi ports: 8443/TCP (GUI), 8080/TCP (inform), 3478/UDP (STUN), 10001/UDP (L2 discovery)"
echo
echo "MongoDB credentials:"
echo "  Root user: ${MONGO_ROOT_USER}"
echo "  Root pass: ${MONGO_ROOT_PASS}"
echo "  App  user: ${MONGO_APP_USER}"
echo "  App  pass: ${MONGO_APP_PASS}"
echo
echo "Next steps:"
echo "  1) Ensure your Caddy build includes: route53 DNS plugin, and any optional plugins you referenced."
echo "  2) Export AWS credentials for Caddy (same shell or service unit):"
echo "       export AWS_ACCESS_KEY='${AWS_ACCESS_KEY}'"
echo "       export AWS_SECRET='${AWS_SECRET}'"
echo "       export AWS_REGION='${AWS_REGION}'"
echo "  3) Point your Caddy at ${UNIFI_DIR}/Caddyfile and reload it."
echo "  4) Start UniFi stack:"
echo "       docker compose -f ${UNIFI_DIR}/docker-compose.yml up -d"
echo
echo "All set."
