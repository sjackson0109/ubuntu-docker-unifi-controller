#!/usr/bin/env bash
# UniFi Network Application + MongoDB 4.4 + Caddy reverse proxy (DNS-01 via Route53)
# Target host: Ubuntu 24.04 (Noble)
# Docker data-root: /mnt/data/docker  (mountpoint on a dedicated 20 GB disk)
# Installation dir: /mnt/data
# UniFi data:       /mnt/data/unifi
# Caddy data:       /mnt/data/caddy
#
# Notes:
# - This script prepares Docker, writes complete Compose stacks for UniFi + MongoDB + Caddy.
# - Caddy is built with the route53 DNS plugin for automatic ACME certificate management.
# - The UniFi service is exposed on standard ports; adjust firewall rules as required.
# - Caddy handles SSL termination and reverse proxy to UniFi controller.
#
# Usage:
#   sudo bash Create.sh
#
# After running:
#   • Start the complete stack with: cd /mnt/data && docker compose up -d
#   • Ensure DNS for the chosen $DOMAIN points to your server's public IP.
#   • Access UniFi controller at: https://$DOMAIN

set -Eeuo pipefail

# -----------------------------
# Configuration validation function
# -----------------------------
validate_configuration() {
    local errors=0
    
    echo "=== Pre-deployment Configuration Validation ==="
    
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: This script must be run as root (use sudo)"
        ((errors++))
    fi
    
    # Validate domain
    if [[ -z "${DOMAIN:-}" || "${DOMAIN}" == "unifi.yourdomain.com" ]]; then
        echo "ERROR: DOMAIN not set or using default value. Set with: export DOMAIN=your-domain.com"
        ((errors++))
    fi
    
    # Validate email
    if [[ -z "${EMAIL:-}" || "${EMAIL}" == "admin@example.com" ]]; then
        echo "ERROR: EMAIL not set or using default value. Set with: export EMAIL=your-email@domain.com"
        ((errors++))
    fi
    
    # Validate AWS credentials
    if [[ -z "${AWS_ACCESS_KEY:-}" ]]; then
        echo "ERROR: AWS_ACCESS_KEY not set. Required for Route53 DNS challenge"
        ((errors++))
    fi
    
    if [[ -z "${AWS_SECRET:-}" ]]; then
        echo "ERROR: AWS_SECRET not set. Required for Route53 DNS challenge"
        ((errors++))
    fi
    
    if [[ -z "${AWS_REGION:-}" ]]; then
        echo "ERROR: AWS_REGION not set. Set with: export AWS_REGION=us-east-1"
        ((errors++))
    fi
    
    # Check system requirements
    local memory_gb=$(free -g | awk '/^Mem:/{print $2}')
    if [[ $memory_gb -lt 4 ]]; then
        echo "WARNING: System has ${memory_gb}GB RAM. Recommended minimum is 4GB"
    fi
    
    # Check disk space
    local disk_space=$(df /mnt 2>/dev/null | tail -1 | awk '{print $4}' || echo "0")
    local disk_space_gb=$((disk_space / 1024 / 1024))
    if [[ $disk_space_gb -lt 20 ]]; then
        echo "WARNING: Available disk space is ${disk_space_gb}GB. Recommended minimum is 20GB"
    fi
    
    # Check if ports are available
    for port in 80 443 8080 3478 10001; do
        if netstat -tuln 2>/dev/null | grep -q ":${port} "; then
            echo "WARNING: Port ${port} is already in use"
        fi
    done
    
    if [[ $errors -gt 0 ]]; then
        echo "❌ Configuration validation FAILED. Please fix the errors above before proceeding."
        exit 1
    else
        echo "✅ Configuration validation PASSED."
    fi
}

# -----------------------------
# Configurable variables
# -----------------------------
DOCKER_DATA_ROOT="/mnt/data/docker"
INSTALL_DIR="/mnt/data"
UNIFI_DIR="/mnt/data/unifi"
CADDY_DIR="/mnt/data/caddy"
DOMAIN="${DOMAIN:-unifi.yourdomain.com}"        # export DOMAIN before running or edit here
EMAIL="${EMAIL:-admin@example.com}"             # ACME email for contact; used by some CAs if needed
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

# AWS for Caddy DNS-01 (Route53). Export these before running or place in your environment for Caddy to read.
AWS_ACCESS_KEY="${AWS_ACCESS_KEY:-}"
AWS_SECRET="${AWS_SECRET:-}"
AWS_REGION="${AWS_REGION:-}"

# Caddy version and build options
CADDY_VERSION="${CADDY_VERSION:-2.8.4}"
CADDY_FULL_BUILD="${CADDY_FULL_BUILD:-false}"  # Set to false for faster build (Route53 only)

# -----------------------------
# Helper
# -----------------------------
need() { command -v "$1" >/dev/null 2>&1 || { echo "Error: '$1' is required." >&2; exit 1; }; }

# Run validation before proceeding
validate_configuration

# -----------------------------
# 1) Prepare Docker Engine with data-root=/srv/docker
# -----------------------------
echo "[1/6] Installing Docker Engine and Compose plugin, and setting data-root to ${DOCKER_DATA_ROOT}..."

# First, clean up any broken Docker configuration
echo "Debug: Checking for existing Docker issues..."
if systemctl is-active --quiet docker; then
    echo "Debug: Docker is running normally"
elif systemctl is-failed --quiet docker; then
    echo "Debug: Docker service is in failed state, cleaning up configuration..."
    sudo systemctl stop docker 2>/dev/null || true
    # Check if daemon.json exists and is problematic
    if [[ -f /etc/docker/daemon.json ]]; then
        echo "Debug: Backing up existing daemon.json..."
        sudo cp /etc/docker/daemon.json /etc/docker/daemon.json.backup 2>/dev/null || true
        # Try to validate the JSON
        if ! python3 -m json.tool /etc/docker/daemon.json >/dev/null 2>&1; then
            echo "Debug: daemon.json is invalid, removing it..."
            sudo rm -f /etc/docker/daemon.json
        fi
    fi
    sudo systemctl reset-failed docker 2>/dev/null || true
else
    echo "Debug: Docker is not installed or not active"
fi

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
echo "Debug: Configuring Docker daemon.json..."
sudo mkdir -p /etc/docker

# Create a clean, properly formatted daemon.json
echo "Debug: Creating fresh daemon.json with data-root configuration..."
sudo tee /etc/docker/daemon.json >/dev/null <<DAEMON_JSON
{
  "data-root": "/mnt/data/docker"
}
DAEMON_JSON

# Validate the JSON format
echo "Debug: Validating daemon.json format..."
if python3 -m json.tool /etc/docker/daemon.json >/dev/null 2>&1; then
    echo "Debug: daemon.json is valid"
else
    echo "ERROR: daemon.json is invalid, this should not happen"
    exit 1
fi

echo "Debug: Reloading systemd and starting Docker..."
sudo systemctl daemon-reload
sudo systemctl enable docker
sudo systemctl start docker

# Wait for Docker to be ready
echo "Debug: Waiting for Docker to be ready..."
for i in {1..30}; do
    if systemctl is-active --quiet docker; then
        echo "Debug: Docker is running successfully"
        break
    fi
    if [[ $i -eq 30 ]]; then
        echo "ERROR: Docker failed to start after 30 seconds"
        echo "Check logs with: sudo journalctl -xeu docker.service"
        exit 1
    fi
    sleep 1
done

# -----------------------------
# 2) Generate secrets and directories for UniFi + MongoDB + Caddy
# -----------------------------
echo "[2/6] Creating directories and generating credentials for UniFi + MongoDB + Caddy..."

# Debug: Show current state
echo "Debug: Checking /mnt/data before directory creation..."
ls -la /mnt/data/ 2>/dev/null || echo "  /mnt/data does not exist yet"

MONGO_APP_USER="unifi"
echo "Debug: Generating MongoDB app password..."
# Use a more reliable password generation method
MONGO_APP_PASS="$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-24)"
if [[ -z "$MONGO_APP_PASS" ]]; then
    echo "ERROR: MongoDB app password is empty, trying alternative method..."
    MONGO_APP_PASS="$(date +%s | sha256sum | base64 | head -c 24)"
fi
if [[ -z "$MONGO_APP_PASS" ]]; then
    echo "ERROR: Failed to generate MongoDB app password with all methods"
    exit 1
fi
echo "Debug: MongoDB app password generated successfully (length: ${#MONGO_APP_PASS})"

MONGO_ROOT_USER="root"
echo "Debug: Generating MongoDB root password..."
# Use a more reliable password generation method
MONGO_ROOT_PASS="$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-28)"
if [[ -z "$MONGO_ROOT_PASS" ]]; then
    echo "ERROR: MongoDB root password is empty, trying alternative method..."
    MONGO_ROOT_PASS="$(date +%s | sha256sum | base64 | head -c 28)"
fi
if [[ -z "$MONGO_ROOT_PASS" ]]; then
    echo "ERROR: Failed to generate MongoDB root password with all methods"
    exit 1
fi
echo "Debug: MongoDB root password generated successfully (length: ${#MONGO_ROOT_PASS})"

echo "Debug: Creating main directory structure..."
echo "  Creating main directories: ${UNIFI_DIR} and ${CADDY_DIR}"
sudo mkdir -p "${UNIFI_DIR}" "${CADDY_DIR}"

echo "Debug: Creating UniFi subdirectories..."
echo "  Creating: ${UNIFI_DIR}/db ${UNIFI_DIR}/data ${UNIFI_DIR}/db-init ${UNIFI_DIR}/backups"
sudo mkdir -p "${UNIFI_DIR}/db" "${UNIFI_DIR}/data" "${UNIFI_DIR}/db-init" "${UNIFI_DIR}/backups"

echo "Debug: Creating Caddy subdirectories..."
echo "  Creating: ${CADDY_DIR}/data ${CADDY_DIR}/config ${CADDY_DIR}/logs"
sudo mkdir -p "${CADDY_DIR}/data" "${CADDY_DIR}/config" "${CADDY_DIR}/logs"

echo "Debug: Setting ownership (PUID=${PUID}, PGID=${PGID})..."
sudo chown -R "${PUID}:${PGID}" "${UNIFI_DIR}/data"
sudo chown -R "${PUID}:${PGID}" "${CADDY_DIR}"
sudo chown -R "${PUID}:${PGID}" "${UNIFI_DIR}/backups"

echo "Debug: Directory creation completed. Current structure:"
ls -la /mnt/data/
echo "UniFi directory:"
ls -la "${UNIFI_DIR}/"
echo "Caddy directory:"
ls -la "${CADDY_DIR}/"

# -----------------------------
# 3) Write Mongo init scripts, UniFi env, Caddy Dockerfile, Compose, and Caddyfile
# -----------------------------
echo "[3/6] Writing Mongo init scripts, UniFi env file, Caddy Dockerfile, docker-compose.yml, and Caddyfile..."
echo "Debug: Starting to write configuration files..."

# Mongo init: ensure root user exists (MongoDB container should handle this via MONGO_INITDB_ROOT_*)
cat > "${UNIFI_DIR}/db-init/01-ensure-root.js" <<JS
// This script ensures the root user is properly configured
// The container's MONGO_INITDB_ROOT_* variables should handle this automatically
try {
  db = db.getSiblingDB("admin");
  // Verify root user exists
  var rootUser = db.getUser("${MONGO_ROOT_USER}");
  if (!rootUser) {
    print("Warning: Root user not found, but this should be created by container init");
  } else {
    print("Root user exists: " + rootUser.user);
  }
} catch (e) {
  print("Note: " + e.message);
}
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
  
  // Create user in admin database with roles for all UniFi databases
  var admin = db.getSiblingDB("admin");
  try {
    // Try to create the user first
    admin.createUser({ 
      user: appUser, 
      pwd: appPass, 
      roles: [
        { role: "dbOwner", db: "unifi" },
        { role: "dbOwner", db: "unifi_stat" },
        { role: "dbOwner", db: "unifi_audit" }
      ]
    });
    print("Created user: " + appUser + " with access to unifi, unifi_stat, and unifi_audit databases");
  } catch (e) { 
    if (e.message.includes("already exists") || e.code === 51003) {
      // User exists, update the password and roles
      try {
        admin.updateUser(appUser, {
          pwd: appPass,
          roles: [
            { role: "dbOwner", db: "unifi" },
            { role: "dbOwner", db: "unifi_stat" },
            { role: "dbOwner", db: "unifi_audit" }
          ]
        });
        print("Updated existing user: " + appUser + " with new password and roles");
      } catch (updateError) {
        print("Failed to update user " + appUser + ": " + updateError.message);
      }
    } else {
      print("User creation error: " + e.message);
    }
  }
})();
JS

# UniFi env file - only create if it doesn't exist
if [[ ! -f "${INSTALL_DIR}/unifi-vars.env" ]]; then
  echo "Debug: Creating new unifi-vars.env file..."
  cat > "${INSTALL_DIR}/unifi-vars.env" <<ENV
PUID=${PUID}
PGID=${PGID}
MONGO_USER=${MONGO_APP_USER}
MONGO_PASS=${MONGO_APP_PASS}
MONGO_HOST=unifi-mongodb
MONGO_PORT=27017
MONGO_DBNAME=unifi
MONGO_AUTHSOURCE=admin
ENV
else
  echo "Debug: Using existing unifi-vars.env file..."
fi

# MongoDB env file - only create if it doesn't exist
if [[ ! -f "${INSTALL_DIR}/mongodb-vars.env" ]]; then
  echo "Debug: Creating new mongodb-vars.env file..."
  cat > "${INSTALL_DIR}/mongodb-vars.env" <<ENV
MONGO_INITDB_ROOT_USERNAME=${MONGO_ROOT_USER}
MONGO_INITDB_ROOT_PASSWORD=${MONGO_ROOT_PASS}
ENV
else
  echo "Debug: Using existing mongodb-vars.env file..."
fi

# Create MongoDB security configuration
echo "Debug: Creating MongoDB security configuration..."
cat > "${UNIFI_DIR}/mongod.conf" <<MONGOD_CONF
# MongoDB Security Configuration
# Network settings
net:
  port: 27017
  bindIp: 0.0.0.0
  maxIncomingConnections: 1000

# Security settings  
security:
  authorization: enabled

# Storage settings
storage:
  dbPath: /data/db
  journal:
    enabled: true
  wiredTiger:
    engineConfig:
      cacheSizeGB: 0.5
      journalCompressor: snappy
    collectionConfig:
      blockCompressor: snappy

# Operation profiling
operationProfiling:
  slowOpThresholdMs: 100
  mode: slowOp

# Logging
systemLog:
  destination: file
  logAppend: true
  path: /var/log/mongodb/mongod.log
  logLevel: 1
MONGOD_CONF

# Caddy Dockerfile with Route53 plugin and optional components
if [[ "${CADDY_FULL_BUILD}" == "true" ]]; then
    echo "Debug: Building Caddy with full plugin set (slower build)..."
    cat > "${CADDY_DIR}/Dockerfile" <<DOCKERFILE
FROM caddy:${CADDY_VERSION}-builder AS builder

RUN xcaddy build \\
    --with github.com/caddy-dns/route53 \\
    --with github.com/mholt/caddy-ratelimit \\
    --with github.com/mastercactapus/caddy2-proxyprotocol
DOCKERFILE
else
    echo "Debug: Building Caddy with Route53 only (faster build)..."
    cat > "${CADDY_DIR}/Dockerfile" <<DOCKERFILE
FROM caddy:${CADDY_VERSION}-builder AS builder

RUN xcaddy build \\
    --with github.com/caddy-dns/route53
DOCKERFILE
fi

cat >> "${CADDY_DIR}/Dockerfile" <<DOCKERFILE

FROM caddy:${CADDY_VERSION}

COPY --from=builder /usr/bin/caddy /usr/bin/caddy

# Create non-root user for security
RUN addgroup -g ${PGID} caddy && \\
    adduser -D -s /bin/sh -u ${PUID} -G caddy caddy

# Set proper permissions
RUN mkdir -p /var/log/caddy && \\
    chown -R caddy:caddy /var/log/caddy && \\
    chown -R caddy:caddy /config && \\
    chown -R caddy:caddy /data

USER caddy

EXPOSE 80 443

CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
DOCKERFILE

# Caddy environment file - only create if it doesn't exist
if [[ ! -f "${INSTALL_DIR}/caddy-vars.env" ]]; then
  echo "Debug: Creating new caddy-vars.env file..."
  cat > "${INSTALL_DIR}/caddy-vars.env" <<ENV
AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY}
AWS_SECRET_ACCESS_KEY=${AWS_SECRET}
AWS_REGION=${AWS_REGION}
ACME_EMAIL=${EMAIL}
DOMAIN=${DOMAIN}
ENV
  
  echo "Debug: Created caddy-vars.env with DOMAIN=${DOMAIN}"
  if [[ "${DOMAIN}" == "unifi.yourdomain.com" ]]; then
    echo "WARNING: Using default domain 'unifi.yourdomain.com'"
    echo "Set a real domain with: export DOMAIN=your-actual-domain.com"
  fi
else
  echo "Debug: Using existing caddy-vars.env file..."
  # Read the existing domain from the file for display
  EXISTING_DOMAIN=$(grep "^DOMAIN=" "${INSTALL_DIR}/caddy-vars.env" | cut -d'=' -f2)
  echo "Debug: Existing DOMAIN=${EXISTING_DOMAIN}"
fi

# Main Docker Compose file (at root level) with enhanced security and resource limits
cat > "${INSTALL_DIR}/docker-compose.yml" <<'YML'
services:
  caddy:
    build: 
      context: ./caddy
      dockerfile: Dockerfile
    container_name: caddy
    hostname: caddy
    restart: unless-stopped
    networks:
      - frontend
      - backend
    ports:
      - "80:80"
      - "443:443"
    env_file:
      - ./caddy-vars.env
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - ./caddy/data:/data
      - ./caddy/config:/config
      - ./caddy/logs:/var/log/caddy
    depends_on:
      - unifi
    deploy:
      resources:
        limits:
          memory: 512M
          cpus: '0.5'
        reservations:
          memory: 256M
          cpus: '0.25'
    healthcheck:
      test: ["CMD", "caddy", "version"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    security_opt:
      - no-new-privileges:true
    read_only: true
    tmpfs:
      - /tmp:noexec,nosuid,size=100m

  unifi:
    container_name: unifi
    hostname: unifi
    image: lscr.io/linuxserver/unifi-network-application:latest
    restart: unless-stopped
    networks:
      - backend
    ports:
      - "3478:3478/udp"    # STUN
      - "10001:10001/udp"  # AP/Device discovery (L2)
      - "8080:8080"        # Device inform (L3 adoption)
      - "8843:8843"        # Guest portal HTTPS (optional)
      - "8880:8880"        # Guest portal HTTP (optional)
      - "6789:6789"        # Speed test (optional)
      - "8443:8443"        # UniFi HTTPS (exposed for direct access)
    env_file:
      - ./unifi-vars.env
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - ./unifi/data:/config
    depends_on:
      unifi-mongodb:
        condition: service_healthy
    deploy:
      resources:
        limits:
          memory: 2G
          cpus: '1.0'
        reservations:
          memory: 1G
          cpus: '0.5'
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8443/status", "||", "exit", "1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 120s
    security_opt:
      - no-new-privileges:true

  unifi-mongodb:
    container_name: unifi-mongodb
    hostname: unifi-mongodb
    image: mongo:4.4
    restart: unless-stopped
    command: ["--config", "/etc/mongod.conf", "--auth"]
    networks:
      - backend
    env_file:
      - ./mongodb-vars.env
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - ./unifi/db:/data/db
      - ./unifi/db-init:/docker-entrypoint-initdb.d:ro
      - ./unifi/backups:/backups
      - ./unifi/mongod.conf:/etc/mongod.conf:ro
    deploy:
      resources:
        limits:
          memory: 1G
          cpus: '0.5'
        reservations:
          memory: 512M
          cpus: '0.25'
    healthcheck:
      test: ["CMD", "mongo", "--quiet", "--eval", "db.runCommand({ping:1}).ok"]
      interval: 15s
      timeout: 10s
      retries: 5
      start_period: 30s
    security_opt:
      - no-new-privileges:true

networks:
  frontend:
    driver: bridge
    ipam:
      config:
        - subnet: 172.20.1.0/24
  backend:
    driver: bridge
    ipam:
      config:
        - subnet: 172.20.2.0/24
YML

# Add rate limiting if full build is enabled
RATE_LIMITING_CONFIG=""
if [[ "${CADDY_FULL_BUILD}" == "true" ]]; then
    RATE_LIMITING_CONFIG="
	# Rate limiting and connection controls for enhanced security
	rate_limit {
		zone default {
			key {remote}
			rate 10r/m
		}
	}

	# Connection limits (requires proxy protocol plugin)
	conn_per_ip 1000
	conn_count 25000"
else
    RATE_LIMITING_CONFIG="
	# Rate limiting disabled (requires additional plugins)
	# To enable: set CADDY_FULL_BUILD=true and rebuild"
fi

# Hardened Caddyfile with Route53 DNS-01 and security headers
cat > "${CADDY_DIR}/Caddyfile" <<CADDY
{
	# Global options block
	acme_dns route53 {
		access_key_id "{\$AWS_ACCESS_KEY_ID}"
		secret_access_key "{\$AWS_SECRET_ACCESS_KEY}"
		region "{\$AWS_REGION}"
	}
	
	# Optional: Set ACME email
	email {\$ACME_EMAIL}
	
	# Admin API disabled for security
	admin off
}

{\$DOMAIN} {
	reverse_proxy unifi:8443 {
		transport http {
			tls_insecure_skip_verify
		}
	}

	tls {
		protocols tls1.2 tls1.3
		ciphers TLS_AES_256_GCM_SHA384 TLS_CHACHA20_POLY1305_SHA256 TLS_AES_128_GCM_SHA256
		curves secp256r1 secp384r1
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
${RATE_LIMITING_CONFIG}
}
CADDY

# -----------------------------
# 4) Build Caddy image and create .env file template
# -----------------------------
echo "[4/6] Building Caddy image with Route53 plugin..."
echo "Debug: Configuration files written successfully. Starting step 4..."

# AWS credentials are configured in caddy-vars.env
if [[ -z "${AWS_ACCESS_KEY}" || -z "${AWS_SECRET}" || -z "${AWS_REGION}" ]]; then
  echo "WARNING: AWS credentials not provided."
  echo "Before starting the stack, configure your AWS credentials in: /mnt/data/caddy-vars.env"
fi

# Create MongoDB user sync script for runtime updates
echo "Creating MongoDB user synchronization script..."
cat > "${INSTALL_DIR}/sync-mongodb-users.sh" <<'SYNC_SCRIPT'
#!/usr/bin/env bash
# MongoDB User Synchronization Script
# This ensures MongoDB users match the current environment files

set -e

INSTALL_DIR="/mnt/data"

# Source environment files
if [[ -f "${INSTALL_DIR}/mongodb-vars.env" ]]; then
    source "${INSTALL_DIR}/mongodb-vars.env"
else
    echo "ERROR: mongodb-vars.env not found"
    exit 1
fi

if [[ -f "${INSTALL_DIR}/unifi-vars.env" ]]; then
    source "${INSTALL_DIR}/unifi-vars.env"
else
    echo "ERROR: unifi-vars.env not found"
    exit 1
fi

# Check if MongoDB container is running
if ! docker ps --filter "name=unifi-mongodb" --filter "status=running" --quiet | grep -q .; then
    echo "MongoDB container is not running, skipping user sync"
    exit 0
fi

echo "Synchronizing MongoDB users with current environment..."

# Update unifi user password to match environment
docker exec unifi-mongodb mongo admin \
    --username="${MONGO_INITDB_ROOT_USERNAME}" \
    --password="${MONGO_INITDB_ROOT_PASSWORD}" \
    --eval "
try {
    db.updateUser('${MONGO_USER}', {
        pwd: '${MONGO_PASS}',
        roles: [
            { role: 'dbOwner', db: 'unifi' },
            { role: 'dbOwner', db: 'unifi_stat' },
            { role: 'dbOwner', db: 'unifi_audit' }
        ]
    });
    print('SUCCESS: Updated ${MONGO_USER} user password');
} catch (e) {
    if (e.message.includes('User') && e.message.includes('not found')) {
        // User doesn't exist, create it
        try {
            db.createUser({
                user: '${MONGO_USER}',
                pwd: '${MONGO_PASS}',
                roles: [
                    { role: 'dbOwner', db: 'unifi' },
                    { role: 'dbOwner', db: 'unifi_stat' },
                    { role: 'dbOwner', db: 'unifi_audit' }
                ]
            });
            print('SUCCESS: Created ${MONGO_USER} user');
        } catch (createError) {
            print('ERROR: Failed to create user - ' + createError.message);
        }
    } else {
        print('ERROR: Failed to update user - ' + e.message);
    }
}
"

echo "MongoDB user synchronization completed"
SYNC_SCRIPT

chmod +x "${INSTALL_DIR}/sync-mongodb-users.sh"

# -----------------------------
# 5) Create health monitoring and management scripts
# -----------------------------
echo "[5/6] Creating health monitoring and management scripts..."

# Create comprehensive health check script
cat > "${INSTALL_DIR}/health-check.sh" <<'HEALTH_SCRIPT'
#!/usr/bin/env bash
# System Health Check and Monitoring Script
set -euo pipefail

INSTALL_DIR="/mnt/data"
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_status() {
    local status=$1
    local message=$2
    case $status in
        "OK") echo -e "${GREEN}✓${NC} $message" ;;
        "ERROR") echo -e "${RED}✗${NC} $message" ;;
        "WARNING") echo -e "${YELLOW}⚠${NC} $message" ;;
    esac
}

echo "=== UniFi Controller System Health Check ==="
echo "Timestamp: $(date)"
echo

# Check Docker service
echo "Docker Service Status:"
if systemctl is-active --quiet docker; then
    print_status "OK" "Docker service is running"
else
    print_status "ERROR" "Docker service is not running"
fi

# Check container status
echo
echo "Container Status:"
cd "$INSTALL_DIR" 2>/dev/null || { echo "Install directory not found: $INSTALL_DIR"; exit 1; }

if command -v docker compose &> /dev/null; then
    for service in caddy unifi unifi-mongodb; do
        if docker compose ps "$service" 2>/dev/null | grep -q "Up"; then
            print_status "OK" "$service container is running"
        else
            print_status "ERROR" "$service container is not running"
        fi
    done
fi

# Check port connectivity
echo
echo "Port Connectivity:"
for port in 80 443 8080 3478 10001; do
    if netstat -tuln 2>/dev/null | grep -q ":${port} "; then
        print_status "OK" "Port $port is listening"
    else
        print_status "WARNING" "Port $port is not listening"
    fi
done

# Check MongoDB health
echo
echo "MongoDB Health:"
if docker exec unifi-mongodb mongo --quiet --eval "db.runCommand({ping: 1})" &>/dev/null; then
    print_status "OK" "MongoDB is responding"
else
    print_status "ERROR" "MongoDB is not responding"
fi

# Check UniFi application health
echo
echo "UniFi Application Health:"
if curl -s -k --connect-timeout 5 https://localhost:8443/status &>/dev/null; then
    print_status "OK" "UniFi web interface is responding"
else
    print_status "WARNING" "UniFi web interface not responding on port 8443"
fi

# Check Caddy health
echo
echo "Caddy Health:"
if curl -s --connect-timeout 5 http://localhost &>/dev/null; then
    print_status "OK" "Caddy is responding on HTTP"
else
    print_status "WARNING" "Caddy not responding on HTTP"
fi

# Check disk usage
echo
echo "System Resources:"
DISK_USAGE=$(df -h "$INSTALL_DIR" | tail -1 | awk '{print $5}' | sed 's/%//')
if [[ "$DISK_USAGE" -lt 80 ]]; then
    print_status "OK" "Disk usage: ${DISK_USAGE}%"
elif [[ "$DISK_USAGE" -lt 90 ]]; then
    print_status "WARNING" "Disk usage: ${DISK_USAGE}% (consider cleanup)"
else
    print_status "ERROR" "Disk usage: ${DISK_USAGE}% (urgent cleanup needed)"
fi

# Check memory usage
MEMORY_USAGE=$(free | grep Mem | awk '{print int($3/$2 * 100)}')
if [[ "$MEMORY_USAGE" -lt 80 ]]; then
    print_status "OK" "Memory usage: ${MEMORY_USAGE}%"
elif [[ "$MEMORY_USAGE" -lt 90 ]]; then
    print_status "WARNING" "Memory usage: ${MEMORY_USAGE}%"
else
    print_status "ERROR" "Memory usage: ${MEMORY_USAGE}% (critical)"
fi

echo
echo "=== Health Check Complete ==="
echo "For detailed logs: docker compose logs -f"
echo "For real-time stats: docker stats"
HEALTH_SCRIPT

chmod +x "${INSTALL_DIR}/health-check.sh"

# Create system update script
cat > "${INSTALL_DIR}/update-system.sh" <<'UPDATE_SCRIPT'
#!/usr/bin/env bash
# System Update and Maintenance Script
set -euo pipefail

INSTALL_DIR="/mnt/data"
echo "=== UniFi Controller System Update ==="
echo "Timestamp: $(date)"
echo

cd "$INSTALL_DIR"

# Create backup before update
echo "Creating pre-update backup..."
./backup-mongodb.sh "pre-update-$(date +%Y%m%d-%H%M%S)"

# Pull latest images
echo "Pulling latest container images..."
docker compose pull

# Restart services with new images
echo "Restarting services with updated images..."
docker compose up -d

# Wait for services to be healthy
echo "Waiting for services to become healthy..."
sleep 30

# Run health check
echo "Running post-update health check..."
./health-check.sh

echo "=== Update Complete ==="
UPDATE_SCRIPT

chmod +x "${INSTALL_DIR}/update-system.sh"

echo "Created management scripts:"
echo "  Health Check: ${INSTALL_DIR}/health-check.sh"
echo "  System Update: ${INSTALL_DIR}/update-system.sh"

# -----------------------------
# 6) Final output and instructions
# -----------------------------
echo "[6/6] Setup complete! Files written under /mnt/data."
echo
echo "Directory structure:"
echo "  /mnt/data/"
echo "  ├── docker-compose.yml      # Main compose file"
echo "  ├── unifi-vars.env          # UniFi application config"
echo "  ├── mongodb-vars.env        # MongoDB credentials"
echo "  ├── caddy-vars.env          # Caddy-specific variables"
echo "  ├── docker/                 # Docker engine data-root"
echo "  │   └── [Docker internal data: containers, images, volumes, etc.]"
echo "  ├── unifi/"
echo "  │   ├── db-init/            # MongoDB initialization scripts"
echo "  │   ├── data/               # UniFi persistent data"
echo "  │   └── backups/            # MongoDB backup storage"
echo "  └── caddy/"
echo "      ├── Dockerfile          # Custom Caddy build with Route53"
echo "      └── Caddyfile           # Reverse proxy & SSL config"
echo
echo "Access URLs:"
echo "  UniFi Controller: https://${DOMAIN}"
echo "  Direct access:    https://your-server-ip:8443 (after container start)"
echo
echo "MongoDB credentials (save these!):"
echo "  Root user: ${MONGO_ROOT_USER}"
echo "  Root pass: ${MONGO_ROOT_PASS}"
echo "  App  user: ${MONGO_APP_USER}"
echo "  App  pass: ${MONGO_APP_PASS}"
echo
echo "Caddy build configuration:"
if [[ "${CADDY_FULL_BUILD}" == "true" ]]; then
  echo "  • Full build: Route53 + Rate Limiting + Proxy Protocol (slower build)"
else
  echo "  • Minimal build: Route53 only (faster build)"
  echo "  • To enable rate limiting: export CADDY_FULL_BUILD=true before running"
fi
echo
echo "To start the complete stack:"
echo "  cd /mnt/data"
if [[ -z "${AWS_ACCESS_KEY}" || -z "${AWS_SECRET}" || -z "${AWS_REGION}" ]]; then
  echo "  # First, configure your AWS credentials in caddy-vars.env:"
  echo "  nano /mnt/data/caddy-vars.env"
fi
echo "  docker compose up -d"
echo "  # Wait for MongoDB to be ready, then sync users:"
echo "  sleep 30 && ./sync-mongodb-users.sh"
echo
echo "Important notes:"
echo "  • Ensure DNS for '${DOMAIN}' points to this server's public IP"
echo "  • Firewall: Allow ports 80, 443 (Caddy), 8080 (UniFi inform), 3478/UDP (STUN), 10001/UDP (discovery)"
echo "  • First setup: Access https://${DOMAIN} and follow UniFi setup wizard"
echo "  • UniFi data persists in /mnt/data/unifi/data/"
echo
echo "Setup complete!"

# -----------------------------
# Create MongoDB backup/restore scripts
# -----------------------------
echo
echo "Creating MongoDB backup/restore scripts..."

# Create backup script
cat > "${INSTALL_DIR}/backup-mongodb.sh" <<'BACKUP_SCRIPT'
#!/usr/bin/env bash
# MongoDB Backup Script for UniFi Controller
# Usage: ./backup-mongodb.sh [backup-name]

set -e

INSTALL_DIR="/mnt/data"
BACKUP_NAME="${1:-backup-$(date +%Y%m%d-%H%M%S)}"
BACKUP_DIR="${INSTALL_DIR}/unifi/backups"

echo "Creating MongoDB backup: ${BACKUP_NAME}"
echo "Backup location: ${BACKUP_DIR}/${BACKUP_NAME}"

# Ensure backup directory exists
mkdir -p "${BACKUP_DIR}"

# Check if MongoDB container is running
if ! docker ps --filter "name=unifi-mongodb" --filter "status=running" --quiet | grep -q .; then
    echo "ERROR: MongoDB container (unifi-mongodb) is not running!"
    echo "Start it with: cd ${INSTALL_DIR} && docker compose up -d unifi-mongodb"
    exit 1
fi

# Create backup using mongodump
echo "Running mongodump..."
docker exec unifi-mongodb mongodump \
    --username="${MONGO_INITDB_ROOT_USERNAME:-root}" \
    --password="${MONGO_INITDB_ROOT_PASSWORD}" \
    --authenticationDatabase=admin \
    --out="/backups/${BACKUP_NAME}" \
    --gzip

# Create a compressed archive
echo "Compressing backup..."
cd "${BACKUP_DIR}"
tar -czf "${BACKUP_NAME}.tar.gz" "${BACKUP_NAME}"
rm -rf "${BACKUP_NAME}"

# Get backup size
BACKUP_SIZE=$(du -h "${BACKUP_NAME}.tar.gz" | cut -f1)

echo "Backup completed successfully!"
echo "File: ${BACKUP_DIR}/${BACKUP_NAME}.tar.gz"
echo "Size: ${BACKUP_SIZE}"
echo
echo "To restore this backup later:"
echo "   ./restore-mongodb.sh ${BACKUP_NAME}.tar.gz"
BACKUP_SCRIPT

# Create restore script
cat > "/mnt/data/restore-mongodb.sh" <<'RESTORE_SCRIPT'
#!/usr/bin/env bash
# MongoDB Restore Script for UniFi Controller
# Usage: ./restore-mongodb.sh <backup-file.tar.gz>

set -e

INSTALL_DIR="/mnt/data"
BACKUP_FILE="${1}"

if [[ -z "${BACKUP_FILE}" ]]; then
    echo "ERROR: Please specify a backup file to restore"
    echo "Usage: $0 <backup-file.tar.gz>"
    echo
    echo "Available backups:"
    ls -la "${INSTALL_DIR}/unifi/backups/"*.tar.gz 2>/dev/null || echo "  No backups found"
    exit 1
fi

# Check if backup file exists
if [[ ! -f "${BACKUP_FILE}" ]]; then
    # Try looking in the backups directory
    BACKUP_PATH="${INSTALL_DIR}/unifi/backups/${BACKUP_FILE}"
    if [[ -f "${BACKUP_PATH}" ]]; then
        BACKUP_FILE="${BACKUP_PATH}"
    else
        echo "ERROR: Backup file not found: ${BACKUP_FILE}"
        exit 1
    fi
fi

echo "Restoring MongoDB from: ${BACKUP_FILE}"
echo "WARNING: This will overwrite the current UniFi database!"
echo
read -p "Are you sure you want to continue? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Restore cancelled."
    exit 0
fi

# Check if MongoDB container is running
if ! docker ps --filter "name=unifi-mongodb" --filter "status=running" --quiet | grep -q .; then
    echo "ERROR: MongoDB container (unifi-mongodb) is not running!"
    echo "Start it with: cd ${INSTALL_DIR} && docker compose up -d unifi-mongodb"
    exit 1
fi

# Stop UniFi container during restore
echo "Stopping UniFi container..."
cd "${INSTALL_DIR}" && docker compose stop unifi

# Extract backup to temp directory
BACKUP_DIR="${INSTALL_DIR}/unifi/backups"
TEMP_DIR="${BACKUP_DIR}/temp-restore-$$"
mkdir -p "${TEMP_DIR}"

echo "Extracting backup..."
tar -xzf "${BACKUP_FILE}" -C "${TEMP_DIR}"

# Find the backup directory (should be the only directory in temp)
RESTORE_DIR=$(find "${TEMP_DIR}" -maxdepth 1 -type d -not -path "${TEMP_DIR}" | head -n1)

if [[ -z "${RESTORE_DIR}" ]]; then
    echo "ERROR: Could not find backup data in archive"
    rm -rf "${TEMP_DIR}"
    exit 1
fi

# Copy backup into container
echo "Copying backup data to container..."
docker cp "${RESTORE_DIR}" unifi-mongodb:/tmp/restore-backup

# Restore databases
echo "Restoring databases..."
docker exec unifi-mongodb mongorestore \
    --username="${MONGO_INITDB_ROOT_USERNAME:-root}" \
    --password="${MONGO_INITDB_ROOT_PASSWORD}" \
    --authenticationDatabase=admin \
    --drop \
    --gzip \
    /tmp/restore-backup

# Clean up
echo "Cleaning up..."
docker exec unifi-mongodb rm -rf /tmp/restore-backup
rm -rf "${TEMP_DIR}"

# Start UniFi container
echo "Starting UniFi container..."
cd "${INSTALL_DIR}" && docker compose start unifi

echo "Restore completed successfully!"
echo "Your UniFi Controller should now be accessible with the restored data."
RESTORE_SCRIPT

# Make scripts executable
chmod +x "/mnt/data/backup-mongodb.sh"
chmod +x "/mnt/data/restore-mongodb.sh"

echo "MongoDB Management Scripts created:"
echo "  Backup:  /mnt/data/backup-mongodb.sh"
echo "  Restore: /mnt/data/restore-mongodb.sh"

# -----------------------------
# Create automated backup scheduler and cleanup
# -----------------------------
echo
echo "Setting up automated backup scheduling..."

# Create backup cleanup script
cat > "/mnt/data/cleanup-backups.sh" <<'CLEANUP_SCRIPT'
#!/usr/bin/env bash
# MongoDB Backup Cleanup Script
# Removes backups older than specified days, keeps minimum number of backups

set -e

INSTALL_DIR="/mnt/data"
BACKUP_DIR="${INSTALL_DIR}/unifi/backups"
DAYS_TO_KEEP="${1:-7}"        # Keep backups for 7 days by default
MIN_BACKUPS_TO_KEEP="${2:-3}" # Always keep at least 3 backups

echo "Cleaning up old MongoDB backups..."
echo "Backup directory: ${BACKUP_DIR}"
echo "Keeping backups newer than ${DAYS_TO_KEEP} days"
echo "Minimum backups to keep: ${MIN_BACKUPS_TO_KEEP}"

if [[ ! -d "${BACKUP_DIR}" ]]; then
    echo "INFO: Backup directory doesn't exist yet: ${BACKUP_DIR}"
    exit 0
fi

cd "${BACKUP_DIR}"

# Count total backups
TOTAL_BACKUPS=$(find . -name "*.tar.gz" -type f | wc -l)
echo "Total backups found: ${TOTAL_BACKUPS}"

if [[ ${TOTAL_BACKUPS} -le ${MIN_BACKUPS_TO_KEEP} ]]; then
    echo "Not enough backups to clean (${TOTAL_BACKUPS} <= ${MIN_BACKUPS_TO_KEEP})"
    exit 0
fi

# Find old backups
OLD_BACKUPS=$(find . -name "*.tar.gz" -type f -mtime +${DAYS_TO_KEEP} | sort)

if [[ -z "${OLD_BACKUPS}" ]]; then
    echo "No old backups found to clean"
    exit 0
fi

# Count old backups
OLD_COUNT=$(echo "${OLD_BACKUPS}" | wc -l)
BACKUPS_AFTER_CLEANUP=$((TOTAL_BACKUPS - OLD_COUNT))

echo "Found ${OLD_COUNT} old backup(s) to potentially remove"
echo "Backups remaining after cleanup: ${BACKUPS_AFTER_CLEANUP}"

# Ensure we don't go below minimum
if [[ ${BACKUPS_AFTER_CLEANUP} -lt ${MIN_BACKUPS_TO_KEEP} ]]; then
    BACKUPS_TO_REMOVE=$((TOTAL_BACKUPS - MIN_BACKUPS_TO_KEEP))
    if [[ ${BACKUPS_TO_REMOVE} -gt 0 ]]; then
        echo "WARNING: Adjusting cleanup to keep minimum ${MIN_BACKUPS_TO_KEEP} backups"
        # Remove oldest backups, but keep minimum
        OLD_BACKUPS=$(find . -name "*.tar.gz" -type f -printf '%T+ %p\n' | sort | head -n ${BACKUPS_TO_REMOVE} | cut -d' ' -f2-)
    else
        echo "Cannot clean any backups without going below minimum"
        exit 0
    fi
fi

if [[ -n "${OLD_BACKUPS}" ]]; then
    echo "Removing old backups:"
    echo "${OLD_BACKUPS}" | while read -r backup; do
        if [[ -f "${backup}" ]]; then
            SIZE=$(du -h "${backup}" | cut -f1)
            echo "  Removing: ${backup} (${SIZE})"
            rm -f "${backup}"
        fi
    done
    
    REMAINING=$(find . -name "*.tar.gz" -type f | wc -l)
    echo "Cleanup completed. ${REMAINING} backup(s) remaining."
else
    echo "No backups to clean"
fi
CLEANUP_SCRIPT

# Create scheduled backup script with logging
cat > "/mnt/data/scheduled-backup.sh" <<SCHEDULED_SCRIPT
#!/usr/bin/env bash
# Scheduled MongoDB Backup Script with Logging
# This script is called by cron for automated backups

set -e

INSTALL_DIR="/mnt/data"
LOG_FILE="/var/log/unifi-backup.log"
BACKUP_NAME="auto-\$(date +%Y%m%d-%H%M%S)"

# Ensure log file exists and is writable
sudo touch "\${LOG_FILE}"
sudo chmod 666 "\${LOG_FILE}"

# Function to log with timestamp
log() {
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - \$1" | tee -a "\${LOG_FILE}"
}

log "Starting automated MongoDB backup: \${BACKUP_NAME}"

# Change to installation directory where scripts are located
cd "\${INSTALL_DIR}"

# Run backup
if ./backup-mongodb.sh "\${BACKUP_NAME}" >> "\${LOG_FILE}" 2>&1; then
    log "Backup completed successfully: \${BACKUP_NAME}.tar.gz"
    
    # Run cleanup (keep 7 days, minimum 3 backups)
    if ./cleanup-backups.sh 7 3 >> "\${LOG_FILE}" 2>&1; then
        log "Backup cleanup completed successfully"
    else
        log "WARNING: Backup cleanup failed, but backup was successful"
    fi
else
    log "ERROR: Backup failed for \${BACKUP_NAME}"
    exit 1
fi

log "Automated backup cycle completed"
SCHEDULED_SCRIPT

# Make scripts executable
chmod +x "/mnt/data/cleanup-backups.sh"
chmod +x "/mnt/data/scheduled-backup.sh"

# Create systemd service for better logging (optional)
cat > "/mnt/data/unifi-backup.service" <<SERVICE
[Unit]
Description=UniFi Controller MongoDB Backup
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
User=root
WorkingDirectory=/mnt/data
ExecStart=/mnt/data/scheduled-backup.sh
StandardOutput=append:/var/log/unifi-backup.log
StandardError=append:/var/log/unifi-backup.log

[Install]
WantedBy=multi-user.target
SERVICE

# Create systemd timer for the service
cat > "/mnt/data/unifi-backup.timer" <<TIMER
[Unit]
Description=Run UniFi MongoDB Backup Daily
Requires=unifi-backup.service

[Timer]
# Run daily at 2 AM
OnCalendar=daily
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
TIMER

echo
echo "Automated backup system created!"
echo "Files created:"
echo "  Cleanup script: /mnt/data/cleanup-backups.sh"
echo "  Scheduled backup: /mnt/data/scheduled-backup.sh"
echo "  Systemd service: /mnt/data/unifi-backup.service"
echo "  Systemd timer: /mnt/data/unifi-backup.timer"
echo
echo "To enable automated daily backups (choose ONE method):"
echo
echo "METHOD 1 - Using systemd (recommended):"
echo "  sudo cp /mnt/data/unifi-backup.* /etc/systemd/system/"
echo "  sudo systemctl daemon-reload"
echo "  sudo systemctl enable unifi-backup.timer"
echo "  sudo systemctl start unifi-backup.timer"
echo "  sudo systemctl status unifi-backup.timer"
echo
echo "METHOD 2 - Using cron:"
echo "  sudo crontab -e"
echo "  # Add this line for daily backups at 2 AM:"
echo "  0 2 * * * cd /mnt/data && ./scheduled-backup.sh"
echo
echo "Backup configuration:"
echo "  • Daily automatic backups at 2:00 AM"
echo "  • Keeps backups for 7 days"
echo "  • Always maintains minimum of 3 backups"
echo "  • Logs to /var/log/unifi-backup.log"
echo "  • Backup naming: auto-YYYYMMDD-HHMMSS.tar.gz"
echo
echo "Manual cleanup (if needed):"
echo "  ./cleanup-backups.sh [days] [min_backups]"
echo "  Example: ./cleanup-backups.sh 14 5  # Keep 14 days, min 5 backups"