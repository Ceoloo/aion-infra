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

echo "[bootstrap] app dir /opt/aion — ROOT-OWNED (deploy the compose profile here)"
# Root-owned so the scoped-sudo model holds: the deploy user must not be able to
# edit the script it may run as root, nor read the 0600 .env. It only needs
# read+traverse. deploy.sh (running as root) writes .env itself.
install -o root -g root -m 0755 -d /opt/aion

echo "[bootstrap] scoped sudo: ${DEPLOY_USER} may run ONLY the deploy entrypoint as root"
cat > /etc/sudoers.d/aion-deploy <<EOF
# CI deploy path: the ONLY privileged action is the deployment entrypoint.
# CI passes the resolved digest ref + commit SHA via these env vars; keep them
# across sudo for this one command only. No shell, no wildcards, no sed-as-root.
Defaults!/opt/aion/scripts/deploy.sh  env_keep += "DEPLOY_IMAGE DEPLOY_GIT_SHA DEPLOY_RELEASE_TAG"
${DEPLOY_USER} ALL=(root) NOPASSWD: /opt/aion/scripts/deploy.sh
EOF
chmod 0440 /etc/sudoers.d/aion-deploy
visudo -c -f /etc/sudoers.d/aion-deploy

echo "[bootstrap] done. Notes:"
echo "  - Docker daemon access ≈ root; only the ${DEPLOY_USER} deploy user is in the docker group."
echo "  - Put providers/vps/{docker-compose.yml,system,scripts,traefik,legacy} in /opt/aion as ROOT (0644/0755)."
echo "  - Create /opt/aion/.env as root:root 0600 from .env.example (contains AION_LOCAL_DB + secrets)."
echo "  - CI SSHes as ${DEPLOY_USER} and runs: sudo -n /opt/aion/scripts/deploy.sh   (scoped rule above)."
echo "  - OPS-001: this host should already run Traefik on :80/:443. Do NOT install Caddy beside it."
echo "  - Join Traefik's Docker network via AION_TRAEFIK_NETWORK in .env (see .env.example)."
echo "  - Postgres (Mode A) binds to 127.0.0.1 only; never open 5432 in ufw."
echo "  - Prefer hostname runtime.aionsystems.ai (stable) over the Hostinger machine FQDN."
