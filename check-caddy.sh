#!/usr/bin/env bash
# Quick Caddy Status Check Script

echo "=== Caddy Container Status ==="
docker ps --filter "name=caddy" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

echo
echo "=== Port Bindings ==="
sudo netstat -tlnp | grep -E ":80|:443" || echo "No processes listening on ports 80/443"

echo
echo "=== Recent Caddy Logs (last 10 lines) ==="
docker logs --tail 10 caddy 2>/dev/null || echo "Caddy container not found or not running"

echo
echo "=== HTTP Response Test ==="
if curl -I -s --connect-timeout 3 http://localhost >/dev/null 2>&1; then
    echo "✓ HTTP (port 80) responding"
else
    echo "✗ HTTP (port 80) not responding"
fi

echo
echo "=== HTTPS Response Test ==="
if curl -I -s -k --connect-timeout 3 https://localhost >/dev/null 2>&1; then
    echo "✓ HTTPS (port 443) responding"
else
    echo "✗ HTTPS (port 443) not responding"
fi

echo
echo "=== Docker Compose Stack Status ==="
cd /mnt/data 2>/dev/null && docker compose ps || echo "Could not check compose status"