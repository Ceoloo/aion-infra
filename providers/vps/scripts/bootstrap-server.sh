#!/usr/bin/env bash
# ============================================================================
# bootstrap-server.sh — minimal, safe hardening for a fresh Ubuntu VPS.
# ============================================================================
# Prepares a generic Ubuntu server (Hostinger/DO/Hetzner/EC2) to run the AION
# VPS profile. Minimal and pragmatic — NOT an enterprise hardening framework
# (aion-infra §15). Run once as root on a new server; review before running.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }

DEPLOY_USER="${DEPLOY_USER:-aion}"

echo "[bootstrap] base packages + automatic security updates"
apt-get update -y
apt-get install -y --no-install-recommends ca-certificates curl ufw unattended-upgrades
dpkg-reconfigure -f noninteractive unattended-upgrades || true

echo "[bootstrap] Docker (official convenience script is acceptable here, but we"
echo "            use the distro/Docker apt repo instead of curl|sh — §51)"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo "[bootstrap] non-root deploy user (${DEPLOY_USER}) in docker group"
id -u "${DEPLOY_USER}" >/dev/null 2>&1 || adduser --disabled-password --gecos "" "${DEPLOY_USER}"
usermod -aG docker "${DEPLOY_USER}"
install -o "${DEPLOY_USER}" -g "${DEPLOY_USER}" -m 0700 -d "/home/${DEPLOY_USER}/.ssh"

echo "[bootstrap] firewall — expose ONLY 22/80/443; DB is never public (§11,§15)"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

echo "[bootstrap] SSH hardening recommendations (NOT auto-applied — review first):"
cat <<'EOF'
  In /etc/ssh/sshd_config, prefer:
    PasswordAuthentication no      # key-based auth only
    PermitRootLogin no
    PubkeyAuthentication yes
  Then: systemctl restart ssh
  Add the deploy user's public key to /home/aion/.ssh/authorized_keys (0600).
EOF

echo "[bootstrap] app dir /opt/aion (deploy the compose profile here; .env 0600)"
install -o "${DEPLOY_USER}" -g "${DEPLOY_USER}" -m 0750 -d /opt/aion

echo "[bootstrap] done. Notes:"
echo "  - Docker daemon access ≈ root; only the ${DEPLOY_USER} deploy user is in the docker group."
echo "  - Put providers/vps/{docker-compose.yml,Caddyfile,system,scripts} + a 0600 .env in /opt/aion."
echo "  - Postgres (Mode A) binds to 127.0.0.1 only; never open 5432 in ufw."
