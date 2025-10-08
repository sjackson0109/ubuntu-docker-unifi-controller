#!/usr/bin/env bash
# Destroy.sh — undo the ubuntu-docker-unifi-controller setup
# Target layout assumed from Create.sh:
#   - Docker data-root: /mnt/data/docker
#   - Installation dir: /mnt/data
#   - Main compose:     /mnt/data/docker-compose.yml
#   - UniFi data:       /mnt/data/unifi
#   - Caddy data:       /mnt/data/caddy
#
# Defaults:
#   • Stop and remove the complete Docker Compose stack (all containers, networks)
#   • Keep volumes and data on disk
#   • Keep Docker installation and daemon.json as-is
#
# Flags:
#   --delete-data            Delete /mnt/data/unifi and /mnt/data/caddy directories (includes backups)
#   --purge-images           Remove images (unifi, mongo, custom caddy build)
#   --revert-daemon-json     Remove "data-root" from /etc/docker/daemon.json and restart Docker
#   --remove-docker          Apt purge Docker Engine and plugins (keeps /mnt/data by default)
#   --remove-docker-repo     Remove Docker APT repo and keyring
#   --remove-caddyfile       Delete Caddyfile only
#   --yes                    Non-interactive, no confirmation
#   --install-dir DIR        Installation directory (default /mnt/data)
#   --force                  Proceed even if compose files are missing
#
# Usage:
#   sudo bash unifi_teardown.sh [flags]

set -Eeuo pipefail

# -----------------------------
# Defaults and env
# -----------------------------
INSTALL_DIR="/mnt/data"
UNIFI_DIR="/mnt/data/unifi"
CADDY_DIR="/mnt/data/caddy"
CONFIRM="ask"
DELETE_DATA="no"
PURGE_IMAGES="no"
REVERT_DAEMON="no"
REMOVE_DOCKER="no"
REMOVE_DOCKER_REPO="no"
REMOVE_CADDYFILE="no"
FORCE="no"

# -----------------------------
# Parse args
# -----------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --delete-data) DELETE_DATA="yes"; shift ;;
    --purge-images) PURGE_IMAGES="yes"; shift ;;
    --revert-daemon-json) REVERT_DAEMON="yes"; shift ;;
    --remove-docker) REMOVE_DOCKER="yes"; shift ;;
    --remove-docker-repo) REMOVE_DOCKER_REPO="yes"; shift ;;
    --remove-caddyfile) REMOVE_CADDYFILE="yes"; shift ;;
    --yes) CONFIRM="no"; shift ;;
    --force) FORCE="yes"; shift ;;
    --install-dir) INSTALL_DIR="${2}"; UNIFI_DIR="${2}/unifi"; CADDY_DIR="${2}/caddy"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

need() { command -v "$1" >/dev/null 2>&1 || { echo "Error: '$1' is required." >&2; exit 1; }; }

# -----------------------------
# Preconditions
# -----------------------------
need sudo
need bash
need systemctl

if command -v docker >/dev/null 2>&1; then
  :
else
  echo "Warning: docker not found. Will proceed with file cleanup only."
fi

if docker compose version >/dev/null 2>&1; then
  DOCKER_COMPOSE="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  DOCKER_COMPOSE="docker-compose"
else
  DOCKER_COMPOSE=""
fi

COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"

# -----------------------------
# Summary and confirmation
# -----------------------------
echo "Teardown plan:"
echo "  Install directory:   ${INSTALL_DIR}"
echo "  UniFi directory:     ${UNIFI_DIR}"
echo "  Caddy directory:     ${CADDY_DIR}"
echo "  Stop/remove stack:   yes"
echo "  Delete data dir:     ${DELETE_DATA}"
echo "  Purge images:        ${PURGE_IMAGES}"
echo "  Revert daemon.json:  ${REVERT_DAEMON}"
echo "  Remove Docker pkgs:  ${REMOVE_DOCKER}"
echo "  Remove Docker repo:  ${REMOVE_DOCKER_REPO}"
echo "  Remove Caddyfile:    ${REMOVE_CADDYFILE}"
echo

if [[ "${CONFIRM}" == "ask" ]]; then
  read -r -p "Proceed with teardown? [y/N] " ans
  [[ "${ans:-N}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

# -----------------------------
# 1) Stop and remove the stack
# -----------------------------
if [[ -n "${DOCKER_COMPOSE}" && -f "${COMPOSE_FILE}" ]]; then
  echo "[1/6] Bringing stack down via Compose (no volume removal)..."
  (cd "${INSTALL_DIR}" && ${DOCKER_COMPOSE} down --remove-orphans || true)
else
  if [[ "${FORCE}" == "yes" ]] && command -v docker >/dev/null 2>&1; then
    echo "[1/6] Compose file missing. Forcing container removal by name..."
    docker rm -f caddy unifi unifi-mongodb 2>/dev/null || true
  else
    echo "[1/6] Compose not available or compose file missing. Skipping container removal."
  fi
fi

# -----------------------------
# 2) Optional: remove images
# -----------------------------
if [[ "${PURGE_IMAGES}" == "yes" ]] && command -v docker >/dev/null 2>&1; then
  echo "[2/6] Purging images..."
  docker image rm -f lscr.io/linuxserver/unifi-network-application:latest 2>/dev/null || true
  docker image rm -f mongo:4.4 2>/dev/null || true
  # Remove custom Caddy image (name depends on build context)
  docker image rm -f mnt-data-caddy:latest 2>/dev/null || true
  docker image rm -f data-caddy:latest 2>/dev/null || true
  docker image rm -f caddy:latest 2>/dev/null || true
fi

# -----------------------------
# 3) Optional: remove Caddyfile only
# -----------------------------
if [[ "${REMOVE_CADDYFILE}" == "yes" ]]; then
  echo "[3/6] Removing Caddyfile..."
  sudo rm -f "${CADDY_DIR}/Caddyfile"
fi

# -----------------------------
# 4) Optional: delete data directory
# -----------------------------
if [[ "${DELETE_DATA}" == "yes" ]]; then
  echo "[4/6] Deleting data directories..."
  # As extra safety, insist the paths match expected prefixes
  case "${UNIFI_DIR}" in
    /mnt/data/unifi|/mnt/data/unifi/)
      echo "  Removing UniFi data: ${UNIFI_DIR}"
      echo "    - Configuration and logs"
      echo "    - MongoDB database files"
      echo "    - Backup files"
      sudo rm -rf "${UNIFI_DIR}"
      ;;
    *)
      echo "Safety check: refusing to delete unexpected UniFi path: ${UNIFI_DIR}" >&2
      exit 3
      ;;
  esac
  
  case "${CADDY_DIR}" in
    /mnt/data/caddy|/mnt/data/caddy/)
      echo "  Removing Caddy data: ${CADDY_DIR}"
      sudo rm -rf "${CADDY_DIR}"
      ;;
    *)
      echo "Safety check: refusing to delete unexpected Caddy path: ${CADDY_DIR}" >&2
      exit 3
      ;;
  esac
  
  # Remove main compose file, env files, and scripts
  sudo rm -f "${INSTALL_DIR}/docker-compose.yml"
  sudo rm -f "${INSTALL_DIR}/unifi-vars.env"
  sudo rm -f "${INSTALL_DIR}/mongodb-vars.env"
  sudo rm -f "${INSTALL_DIR}/caddy-vars.env"
  sudo rm -f "${INSTALL_DIR}/.env"
  sudo rm -f "${INSTALL_DIR}/.env.template"
  sudo rm -f "${INSTALL_DIR}/backup-mongodb.sh"
  sudo rm -f "${INSTALL_DIR}/restore-mongodb.sh"
  sudo rm -f "${INSTALL_DIR}/cleanup-backups.sh"
  sudo rm -f "${INSTALL_DIR}/scheduled-backup.sh"
  sudo rm -f "${INSTALL_DIR}/unifi-backup.service"
  sudo rm -f "${INSTALL_DIR}/unifi-backup.timer"
  
  # Clean up systemd files if they were installed
  if [[ -f "/etc/systemd/system/unifi-backup.service" ]]; then
    echo "  Removing systemd backup service..."
    sudo systemctl stop unifi-backup.timer 2>/dev/null || true
    sudo systemctl disable unifi-backup.timer 2>/dev/null || true
    sudo rm -f /etc/systemd/system/unifi-backup.service
    sudo rm -f /etc/systemd/system/unifi-backup.timer
    sudo systemctl daemon-reload
  fi
  
  # Remove backup log file
  if [[ -f "/var/log/unifi-backup.log" ]]; then
    echo "  Removing backup log file..."
    sudo rm -f /var/log/unifi-backup.log
  fi
fi

# -----------------------------
# 5) Optional: revert daemon.json
# -----------------------------
if [[ "${REVERT_DAEMON}" == "yes" ]]; then
  if [[ -f /etc/docker/daemon.json ]]; then
    echo "[5/6] Reverting /etc/docker/daemon.json 'data-root' and restarting Docker..."
    # Remove the "data-root": "/mnt/data/docker" entry safely
    sudo awk '
      BEGIN{skip=0}
      {
        line=$0
        # Drop lines containing "data-root"
        if (line ~ /"data-root"[[:space:]]*:/) next
        print line
      }
    ' /etc/docker/daemon.json | sudo tee /etc/docker/daemon.json.new >/dev/null
    sudo mv /etc/docker/daemon.json.new /etc/docker/daemon.json
    sudo systemctl daemon-reload
    sudo systemctl restart docker || true
  else
    echo "[5/6] /etc/docker/daemon.json not present. Skipping revert."
  fi
fi

# -----------------------------
# 6) Optional: remove Docker packages and repo
# -----------------------------
if [[ "${REMOVE_DOCKER}" == "yes" ]]; then
  echo "[6/6] Removing Docker Engine and plugins..."
  sudo apt-get -y purge docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || true
  sudo apt-get -y autoremove --purge || true
  # Note: we do not delete ${INSTALL_DIR} by default
fi

if [[ "${REMOVE_DOCKER_REPO}" == "yes" ]]; then
  echo "[6/6b] Removing Docker APT repo and keyring..."
  sudo rm -f /etc/apt/sources.list.d/docker.list
  sudo rm -f /etc/apt/keyrings/docker.asc
  sudo apt-get update -y || true
fi

echo
echo "Teardown complete."
if [[ "${DELETE_DATA}" != "yes" ]]; then
  echo "Data preserved at:"
  echo "  UniFi data: ${UNIFI_DIR}"
  echo "  Caddy data: ${CADDY_DIR}"
  echo "  Backup scripts: ${INSTALL_DIR}/*.sh"
  echo "  Note: Automated backups may still be scheduled (check crontab/systemd)"
else
  echo "All data, backups, and automation scripts have been removed."
  echo "Systemd backup services have been disabled and removed."
fi
echo "Install directory remains at: ${INSTALL_DIR}  (unless you changed it with --revert-daemon-json)"
