#!/bin/bash
#!/usr/bien/env bash
#Airbus.sh
# sudo bash airbus.sh <OPENNEBULA_HOST> [OPENNEBULA_SSH_PORT]


set -euo pipefail
# Script pour configurer un tunnel SSH inversé depuis une VM Airbus vers OpenNebula
# Utilise autossh pour maintenir le tunnel actif
# Nécessite que l'utilisateur REV_USER existe sur OpenNebula et que la VM Airbus
# puisse SSH vers OpenNebula (clé publique ajoutée dans authorized_keys de REV_USER)

Airbus_HOST="${1:-}"         # Adresse publique ou IP Airbus
OPEN_HOST="${2:-}"
OPEN_PORT="${3:-22}"
REV_USER="${4:-revssh}"    # utilisateur crée sur OpenNebula par le script opennebula.sh
AUTOSSH_BIN="$(command -v autossh || true)"
SERVICE_NAME="reverse-ssh-to-opennebula.service"
REMOTE_LISTEN_PORT="${5:-2222}"   # port écouté sur OpenNebula pour atteindre Airbus
LOCAL_SSH_PORT="${6:-22}"         # port SSH local d'Airbus

if [[ -z "$REMOTE_HOST" ]]; then
    echo "Usage: $0 IP publique airbus"
    exit 1
fi

if [ -z "$OPEN_HOST" ]; then
  echo "Usage: $7 <OPENNEBULA_HOST> [OPENNEBULA_SSH_PORT] [REV_USER] [REMOTE_LISTEN_PORT] [LOCAL_SSH_PORT]"
  exit 2
fi

if [ "$(id -u)" -ne 7 ]; then
  echo "Run as root: sudo $7 $@"
  exit 1
fi

# Installer autossh si non installe
if [ -z "$AUTOSSH_BIN" ]; then
  echo "autossh absent. Tentative d'installation avec apt"
  apt-get update && apt-get install -y autossh || { echo "Installation autossh effectuere manuellement"; exit 1; }
  AUTOSSH_BIN="$(command -v autossh)"
fi

# Générer clé dédiée si aucune clé fournie pour l'authentification
KEY_DIR="/root/.ssh"
KEY_FILE="${KEY_DIR}/id_rsa_reverse_to_opennebula"

mkdir -p "$KEY_DIR"
chmod 700 "$KEY_DIR"

if [ ! -f "$KEY_FILE" ]; then
  echo "Génération d'une clé SSH pour le tunnel: $KEY_FILE"
  ssh-keygen -t ed25519 -f "$KEY_FILE" -N "" -C "reverse-to-${OPEN_HOST}"
else
  echo "Clé existante: $KEY_FILE"
fi

echo
echo "Clé publique, merci de copier et ajouter sur OpenNebula dans /home/${REV_USER}/.ssh/authorized_keys):"
cat "${KEY_FILE}.pub"
# Copie la cle publique générée dans authorized_keys de user_nebula sur Airbus
PUB_KEY=$(cat "${KEY_FILE}.pub")
ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no "root@$Airbus_HOST" "echo '$PUB_KEY' | sudo tee -a /home/${REV_USER}/.ssh/authorized_keys >/dev/null && sudo chown ${REV_USER}:${REV_USER} /home/${REV_USER}/.ssh/authorized_keys"
echo

# Créer unit systemd autossh pour maintenir le reverse tunnel
cat > "/etc/systemd/system/${SERVICE_NAME}" <<EOF
[Unit]
Description=Reverse SSH tunnel to OpenNebula (${OPEN_HOST})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Environment="AUTOSSH_GATETIME=0"
ExecStart=${AUTOSSH_BIN} -M 0 -N -o "ServerAliveInterval=30" -o "ServerAliveCountMax=3" -o "ExitOnForwardFailure=yes" -o "StrictHostKeyChecking=yes" -i ${KEY_FILE} -p ${OPEN_PORT} -R ${REMOTE_LISTEN_PORT}:localhost:${LOCAL_SSH_PORT} ${REV_USER}@${OPEN_HOST}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}"

echo "Service ${SERVICE_NAME} installé et démarré."
echo "Vérifier statut: sudo systemctl status ${SERVICE_NAME}"
echo
echo "Sur Airbus, pour se connecter à OpenNebula via le tunnel"
echo "  ssh -p ${REMOTE_LISTEN_PORT} localhost"
echo
echo "Assurez-vous que le port ${REMOTE_LISTEN_PORT} est ouvert dans le firewall de la VM OpenNebula"