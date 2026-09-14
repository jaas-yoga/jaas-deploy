#!/usr/bin/env bash
# One-time setup for the "api" VM (jaas-registry + jaas-guardrails + Caddy).
# Run once, by hand, as root/sudo on a fresh Ubuntu 24.04
# VM.Standard.E2.1.Micro:
#
#   scp -r provisioning ubuntu@<api-vm-ip>:~/provisioning
#   ssh ubuntu@<api-vm-ip>
#   sudo bash ~/provisioning/provision-api-vm.sh <API_DOMAIN> <deploy-ssh-public-key>
#
# Idempotent: safe to re-run (e.g. after changing API_DOMAIN).
set -euo pipefail

API_DOMAIN="${1:?Usage: provision-api-vm.sh <API_DOMAIN> <deploy-ssh-public-key>}"
DEPLOY_PUBKEY="${2:?Usage: provision-api-vm.sh <API_DOMAIN> <deploy-ssh-public-key>}"
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
cat > /etc/sudoers.d/jaas-deploy <<EOF
jaas ALL=(root) NOPASSWD: /usr/bin/systemctl restart jaas-registry, /usr/bin/systemctl status jaas-registry, /usr/bin/systemctl restart jaas-guardrails, /usr/bin/systemctl status jaas-guardrails
EOF
chmod 440 /etc/sudoers.d/jaas-deploy

# --- Python 3.12 + uv ---
apt-get update
apt-get install -y python3.12 python3.12-venv
if ! command -v uv &>/dev/null; then
  curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh
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
for svc in registry guardrails; do
  install -d -m 755 -o jaas -g jaas "/opt/jaas/${svc}/releases"
  install -d -m 750 -o jaas -g jaas "/opt/jaas/${svc}/shared"
done

if [ ! -f /opt/jaas/registry/shared/env ]; then
  cat > /opt/jaas/registry/shared/env <<'EOF'
# Fill in and chmod 600. See deploy/.env.example in jaas-skills.
JAAS_JWT_SECRET=
JAAS_GOOGLE_CLIENT_ID=
JAAS_DEV_LOGIN_PASSWORD=
JAAS_PLATFORM_ADMIN_EMAILS=
JAAS_PASSWORD_PEPPER=
JAAS_TURNSTILE_SECRET_KEY=
JAAS_GITHUB_OAUTH_REDIRECT_URI=https://__API_DOMAIN__/api/v1/github/callback
JAAS_WEB_APP_URL=
JAAS_STORAGE_BACKEND=local
EOF
  sed -i "s/__API_DOMAIN__/${API_DOMAIN}/" /opt/jaas/registry/shared/env
  chown jaas:jaas /opt/jaas/registry/shared/env
  chmod 600 /opt/jaas/registry/shared/env
  echo ">>> Edit /opt/jaas/registry/shared/env before starting jaas-registry."
fi

if [ ! -f /opt/jaas/guardrails/shared/env ]; then
  touch /opt/jaas/guardrails/shared/env
  chown jaas:jaas /opt/jaas/guardrails/shared/env
  chmod 600 /opt/jaas/guardrails/shared/env
fi

# --- systemd units ---
cp "$SCRIPT_DIR/systemd/jaas-registry.service" /etc/systemd/system/jaas-registry.service
cp "$SCRIPT_DIR/systemd/jaas-guardrails.service" /etc/systemd/system/jaas-guardrails.service
systemctl daemon-reload
systemctl enable jaas-registry jaas-guardrails

# --- Caddy config ---
sed "s/__API_DOMAIN__/${API_DOMAIN}/" "$SCRIPT_DIR/Caddyfile.api" > /etc/caddy/Caddyfile
systemctl enable caddy
systemctl restart caddy

echo ">>> API VM provisioned. Next: fill in /opt/jaas/registry/shared/env, then"
echo ">>>   systemctl start jaas-guardrails jaas-registry"
echo ">>> First deploy from CI will populate /opt/jaas/{registry,guardrails}/current."
echo ">>> Don't forget: back on the web VM, set JAAS_API_URL in"
echo ">>> /opt/jaas/ui/shared/env to this VM's private IP."
