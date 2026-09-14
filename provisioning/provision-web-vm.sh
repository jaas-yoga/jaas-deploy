#!/usr/bin/env bash
# One-time setup for the "web" VM (jaas-ui + Caddy). Run once, by hand, as
# root/sudo on a fresh Ubuntu 24.04 VM.Standard.E2.1.Micro:
#
#   scp -r provisioning ubuntu@<web-vm-ip>:~/provisioning
#   ssh ubuntu@<web-vm-ip>
#   sudo bash ~/provisioning/provision-web-vm.sh <DOMAIN> <deploy-ssh-public-key>
#
# Idempotent: safe to re-run (e.g. after changing DOMAIN).
set -euo pipefail

DOMAIN="${1:?Usage: provision-web-vm.sh <DOMAIN> <deploy-ssh-public-key>}"
DEPLOY_PUBKEY="${2:?Usage: provision-web-vm.sh <DOMAIN> <deploy-ssh-public-key>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- system user the services and CI deploy over SSH as ---
if ! id jaas &>/dev/null; then
  useradd --system --create-home --shell /usr/sbin/nologin jaas
fi
install -d -m 700 -o jaas -g jaas /home/jaas/.ssh
if ! grep -qF "$DEPLOY_PUBKEY" /home/jaas/.ssh/authorized_keys 2>/dev/null; then
  echo "$DEPLOY_PUBKEY" >> /home/jaas/.ssh/authorized_keys
fi
chmod 600 /home/jaas/.ssh/authorized_keys
chown jaas:jaas /home/jaas/.ssh/authorized_keys
# jaas-deploy's deploy.sh calls `sudo systemctl restart jaas-ui` as this
# user — scope sudo to exactly that, nothing else.
cat > /etc/sudoers.d/jaas-deploy <<EOF
jaas ALL=(root) NOPASSWD: /usr/bin/systemctl restart jaas-ui, /usr/bin/systemctl status jaas-ui
EOF
chmod 440 /etc/sudoers.d/jaas-deploy

# --- Node 24 (NodeSource) ---
if ! command -v node &>/dev/null || [[ "$(node -v)" != v24* ]]; then
  curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
  apt-get install -y nodejs
fi

# --- Caddy (official apt repo) ---
if ! command -v caddy &>/dev/null; then
  apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update
  apt-get install -y caddy
fi

# --- release/env directories ---
install -d -m 755 -o jaas -g jaas /opt/jaas/ui/releases
install -d -m 750 -o jaas -g jaas /opt/jaas/ui/shared
if [ ! -f /opt/jaas/ui/shared/env ]; then
  cat > /opt/jaas/ui/shared/env <<'EOF'
# Fill in and chmod 600. Never committed — see deploy/.env.example in
# jaas-ui for what each of these does.
AUTH_SECRET=
AUTH_URL=https://__DOMAIN__
AUTH_GOOGLE_ID=
AUTH_GOOGLE_SECRET=
# Private IP of the api VM — set once that VM's details are known.
JAAS_API_URL=http://__API_VM_PRIVATE_IP__:8027
JAAS_DEV_LOGIN_PASSWORD=
EOF
  sed -i "s/__DOMAIN__/${DOMAIN}/" /opt/jaas/ui/shared/env
  chown jaas:jaas /opt/jaas/ui/shared/env
  chmod 600 /opt/jaas/ui/shared/env
  echo ">>> Edit /opt/jaas/ui/shared/env before starting jaas-ui — it has empty secrets."
fi

# --- systemd unit ---
cp "$SCRIPT_DIR/systemd/jaas-ui.service" /etc/systemd/system/jaas-ui.service
systemctl daemon-reload
systemctl enable jaas-ui

# --- Caddy config ---
sed "s/__DOMAIN__/${DOMAIN}/" "$SCRIPT_DIR/Caddyfile.web" > /etc/caddy/Caddyfile
systemctl enable caddy
systemctl restart caddy

echo ">>> Web VM provisioned. Next: fill in /opt/jaas/ui/shared/env, then"
echo ">>>   systemctl start jaas-ui"
echo ">>> First deploy from CI will populate /opt/jaas/ui/current."
