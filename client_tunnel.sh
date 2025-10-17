#!/usr/bin/env bash
# client_tunnel.sh à lancer sur la VM de l'étudiant Airbus ou OpenNebula
# sudo bash client_tunnel.sh RELAIS_HOST [RELAIS_PORT] [RELAIS_USER] [REMOTE_PORT] [LOCAL_SSH_PORT]
# sudo bash client_tunnel.sh ip_relais 22 userA 2221 22
#installe un service autossh-tunnel@2221.service pour garder le tunnel actif.
#Le script génère une clé SSH dédiée au tunnel au cas ou elle n’existe pas
#Affiche la clé restreinte prête à copier sur le relais
#Crée un service systemd pour que le tunnel soit toujours actif
#Le tunnel fait, Relais:TUNNEL_PORT → localhost:LOCAL_SSH_PORT sur le client

set -euo pipefail

RELAIS_HOST="${1:-}"
RELAIS_PORT="${2:-22}"
RELAIS_USER="${3:-userA}"
REMOTE_PORT="${4:-2221}"      # port that will be opened on the Relais server for this client
LOCAL_SSH_PORT="${5:-22}"     # local SSH port on this VM
KEY_PATH="${6:-/root/.ssh/id_ed25519_tunnel}"
SERVICE_NAME="autossh-tunnel@${REMOTE_PORT}.service"

if [ -z "$RELAIS_HOST" ]; then
  echo "Usage: sudo $0 RELAIS_HOST [RELAIS_PORT] [RELAIS_USER] [REMOTE_PORT] [LOCAL_SSH_PORT]"
  exit 2
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "Ce script requiert les privilèges root. Lancez-le avec sudo."
  exit 1
fi

# préparer la clé
KEY_DIR="$(dirname "$KEY_PATH")"
mkdir -p "$KEY_DIR"
chmod 700 "$KEY_DIR"

if [ ! -f "$KEY_PATH" ]; then
  echo "Génération d'une clé SSH pour le tunnel: $KEY_PATH"
  ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -C "tunnel-to-${RELAIS_HOST}:${REMOTE_PORT}"
  chmod 600 "$KEY_PATH"
  chmod 644 "${KEY_PATH}.pub"
else
  echo "Clé existante: $KEY_PATH"
  chmod 600 "$KEY_PATH" || true
fi

PUB_KEY="$(cat "${KEY_PATH}.pub")"

#tenter de copier la clé sur le RELAIS (ssh-copy-id si disponible), sinon fallback print
echo "Tentative de copie de la clé publique sur ${RELAIS_USER}@${RELAIS_HOST}:${RELAIS_PORT}"
if command -v ssh-copy-id >/dev/null 2>&1; then
  # try quick connection (with disabled host checking for first contact)
  SSH_TEST_ARGS="-p ${RELAIS_PORT} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
  if ssh ${SSH_TEST_ARGS} "${RELAIS_USER}@${RELAIS_HOST}" "true" 2>/dev/null; then
    ssh-copy-id -i "${KEY_PATH}.pub" -p "${RELAIS_PORT}" "${RELAIS_USER}@${RELAIS_HOST}" || true
  else
    echo "Connexion au RELAIS impossible (vérifie adresse/port/credentials)."
    echo "---- Clé publique à copier manuellement sur le relais (user: ${RELAIS_USER}) ----"
    echo "$PUB_KEY"
    echo "---- Fin clé publique ----"
    echo "Ajoute-la dans /home/${RELAIS_USER}/.ssh/authorized_keys sur le RELAIS puis relance ce script."
    exit 0
  fi
else
  # fallback: try direct ssh append (may require password)
  if ssh -p "$RELAIS_PORT" -o StrictHostKeyChecking=no "${RELAIS_USER}@${RELAIS_HOST}" "mkdir -p /home/${RELAIS_USER}/.ssh && chmod 700 /home/${RELAIS_USER}/.ssh" >/dev/null 2>&1; then
    ssh -p "$RELAIS_PORT" -o StrictHostKeyChecking=no "${RELAIS_USER}@${RELAIS_HOST}" \
      "echo '$PUB_KEY' >> /home/${RELAIS_USER}/.ssh/authorized_keys && chmod 600 /home/${RELAIS_USER}/.ssh/authorized_keys && chown -R ${RELAIS_USER}:${RELAIS_USER} /home/${RELAIS_USER}/.ssh"
  else
    echo "Impossible de copier la clé automatiquement. Affichage de la clé publique ci-dessous :"
    echo "***** Clé publique *****"
    echo "$PUB_KEY"
    echo "***** Fin clé publique *****"
    echo "Copie manuellement sur ${RELAIS_HOST}:/home/${RELAIS_USER}/.ssh/authorized_keys puis relance ce script"
    echo "no-pty,no-agent-forwarding,no-X11-forwarding,permitopen=\"localhost:${TUNNEL_PORT}\",command=\"/bin/false\""
    exit 0
  fi
fi

#create systemd service unit (template per remote port)
AUTOSSH_BIN="$(command -v autossh)"
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}"

cat > "${UNIT_PATH}" <<EOF
[Unit]
Description=Reverse SSH tunnel to RELAIS %i (RemotePort=${REMOTE_PORT})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Environment="AUTOSSH_GATETIME=0"
ExecStart=${AUTOSSH_BIN} -M 0 -N -o "ServerAliveInterval=60" -o "ServerAliveCountMax=3" -o "ExitOnForwardFailure=yes" -o "StrictHostKeyChecking=yes" -i ${KEY_PATH} -p ${RELAIS_PORT} -R ${REMOTE_PORT}:localhost:${LOCAL_SSH_PORT} ${RELAIS_USER}@${RELAIS_HOST}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}"

echo "Service ${SERVICE_NAME} installé et démarré."
echo "Vérifie le statut : sudo systemctl status ${SERVICE_NAME}"
echo
echo "Sur le RELAIS, pour atteindre ce client : ssh -p ${REMOTE_PORT} localhost"
echo "Si la copie de la clé a été faite manuellement, assure-toi que la clé publique est bien dans /home/${RELAIS_USER}/.ssh/authorized_keys"

#Depuis un poste client, pour joindre OpenNebula (en se servant du bastion comme jump host)
#si GatewayPorts yes est activé
#ssh -p 2221 <user_airbus>@203.0.113.10
echo "ssh -p ${TUNNEL_PORT} <user_sur_cette_VM>@localhost"

