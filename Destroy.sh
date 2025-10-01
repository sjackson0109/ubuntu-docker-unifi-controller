#!/usr/bin/env bash
# unifi_teardown.sh — undo the ubuntu-docker-unifi-controller setup
# Target layout assumed from setup.sh:
#   - Docker data-root: /srv/docker
#   - Stack root:       /srv/docker/unifi
#
# Defaults:
#   • Stop and remove the UniFi Compose stack (containers, networks created by stack)
#   • Keep volumes and data on disk
#   • Keep Docker installation and daemon.json as-is
#
# Flags:
#   --delete-data            Delete /srv/docker/unifi directory (data, db, configs)
#   --purge-images           Remove images (lscr.io/linuxserver/unifi-network-application, mongo:4.4)
#   --revert-daemon-json     Remove "data-root" from /etc/docker/daemon.json and restart Docker
#   --remove-docker          Apt purge Docker Engine and plugins (keeps /srv/docker by default)
#   --remove-docker-repo     Remove Docker APT repo and keyring
#   --remove-caddyfile       Delete /srv/docker/unifi/Caddyfile only
#   --yes                    Non-interactive, no confirmation
#   --stack-dir DIR          Override stack root (default /srv/docker/unifi)
#   --docker-root DIR        Docker data-root for info only (default /srv/docker)
#   --force                  Proceed even if compose files are missing
#
# Usage:
#   sudo bash unifi_teardown.sh [flags]

set -Eeuo pipefail

# -----------------------------
# Defaults and env
# -----------------------------
STACK_DIR="/srv/docker/unifi"
DOCKER_ROOT="/srv/docker"
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
    --stack-dir) STACK_DIR="${2}"; shift 2 ;;
    --docker-root) DOCKER_ROOT="${2}"; shift 2 ;;
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

COMPOSE_FILE="${STACK_DIR}/docker-compose.yml"

# -----------------------------
# Summary and confirmation
# -----------------------------
echo "Teardown plan:"
echo "  Stack directory:     ${STACK_DIR}"
echo "  Docker data-root:    ${DOCKER_ROOT} (info)"
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
  (cd "${STACK_DIR}" && ${DOCKER_COMPOSE} down --remove-orphans || true)
else
  if [[ "${FORCE}" == "yes" ]] && command -v docker >/dev/null 2>&1; then
    echo "[1/6] Compose file missing. Forcing container removal by name..."
    docker rm -f unifi unifi-mongodb 2>/dev/null || true
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
fi

# -----------------------------
# 3) Optional: remove Caddyfile only
# -----------------------------
if [[ "${REMOVE_CADDYFILE}" == "yes" ]]; then
  echo "[3/6] Removing Caddyfile..."
  sudo rm -f "${STACK_DIR}/Caddyfile"
fi

# -----------------------------
# 4) Optional: delete data directory
# -----------------------------
if [[ "${DELETE_DATA}" == "yes" ]]; then
  echo "[4/6] Deleting stack directory ${STACK_DIR} ..."
  # As extra safety, insist the path matches the expected prefix
  case "${STACK_DIR}" in
    /srv/docker/unifi|/srv/docker/unifi/)
      sudo rm -rf "${STACK_DIR}"
      ;;
    *)
      echo "Safety check: refusing to delete unexpected path: ${STACK_DIR}" >&2
      exit 3
      ;;
  esac
fi

# -----------------------------
# 5) Optional: revert daemon.json
# -----------------------------
if [[ "${REVERT_DAEMON}" == "yes" ]]; then
  if [[ -f /etc/docker/daemon.json ]]; then
    echo "[5/6] Reverting /etc/docker/daemon.json 'data-root' and restarting Docker..."
    # Remove the "data-root": "/srv/docker" entry safely
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
  # Note: we do not delete ${DOCKER_ROOT} by default
fi

if [[ "${REMOVE_DOCKER_REPO}" == "yes" ]]; then
  echo "[6/6b] Removing Docker APT repo and keyring..."
  sudo rm -f /etc/apt/sources.list.d/docker.list
  sudo rm -f /etc/apt/keyrings/docker.asc
  sudo apt-get update -y || true
fi

echo
echo "Teardown complete."
echo "If you kept data, it remains under: ${STACK_DIR}"
echo "Docker root remains at: ${DOCKER_ROOT}  (unless you changed it with --revert-daemon-json)"
