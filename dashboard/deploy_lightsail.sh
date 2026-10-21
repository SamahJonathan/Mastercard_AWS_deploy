#!/usr/bin/env bash
# Publica el dashboard en una instancia Lightsail existente (Ubuntu/Debian) como servicio systemd.
#
# Uso:
#   LIGHTSAIL_HOST=1.2.3.4 SSH_KEY=~/.ssh/LightsailDefaultKey-sa-east-1.pem \
#   GOLD_API_URL=https://xxx.execute-api.sa-east-1.amazonaws.com GOLD_API_KEY=... \
#   ./dashboard/deploy_lightsail.sh
#
# Luego abrir el puerto 8501 en Lightsail > Networking > IPv4 Firewall.
set -euo pipefail

: "${LIGHTSAIL_HOST:?}" "${SSH_KEY:?}" "${GOLD_API_URL:?}" "${GOLD_API_KEY:?}"
SSH_USER="${SSH_USER:-ubuntu}"
TARGET="$SSH_USER@$LIGHTSAIL_HOST"
SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=accept-new"

$SSH "$TARGET" "mkdir -p ~/paylake-dashboard"
scp -i "$SSH_KEY" dashboard/app.py dashboard/requirements.txt "$TARGET:~/paylake-dashboard/"

$SSH "$TARGET" bash -s <<EOF
set -euo pipefail
cd ~/paylake-dashboard
sudo apt-get update -qq && sudo apt-get install -y -qq python3-venv >/dev/null
python3 -m venv .venv && .venv/bin/pip install -q -r requirements.txt
umask 077
cat > .env <<ENV
GOLD_API_URL=$GOLD_API_URL
GOLD_API_KEY=$GOLD_API_KEY
ENV
sudo tee /etc/systemd/system/paylake-dashboard.service >/dev/null <<UNIT
[Unit]
Description=Payments Lakehouse dashboard
After=network.target

[Service]
User=$SSH_USER
WorkingDirectory=/home/$SSH_USER/paylake-dashboard
EnvironmentFile=/home/$SSH_USER/paylake-dashboard/.env
ExecStart=/home/$SSH_USER/paylake-dashboard/.venv/bin/streamlit run app.py --server.port 8501 --server.headless true
Restart=always

[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload && sudo systemctl enable --now paylake-dashboard && sudo systemctl restart paylake-dashboard
EOF
echo "Dashboard: http://$LIGHTSAIL_HOST:8501"
