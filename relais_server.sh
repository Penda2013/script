#!/usr/bin/env bash
# setup-bastion-bridge.sh
# Configure un bastion public pour créer un pont sécurisé entre Airbus et OpenNebula
# sudo bash setup-bastion-bridge.sh [RELAIS_USER] [AIRBUS_PORT] [NEBULA_PORT] [BRIDGE_AIRBUS_PORT] [BRIDGE_NEBULA_PORT]
# sudo bash relais_server.sh userA 2221 2222 3001 3000

set -euo pipefail

RELAIS_USER="${1:-userA}"
AIRBUS_PORT="${2:-2221}"         # port du tunnel inversé Airbus sur le relais
NEBULA_PORT="${3:-2222}"         # port du tunnel inversé OpenNebula sur le relais
BRIDGE_AIRBUS_PORT="${4:-3001}"  # port exposé pour OpenNebula vers Airbus
BRIDGE_NEBULA_PORT="${5:-3000}"  # port exposé pour Airbus vers OpenNebula

if [ "$(id -u)" -ne 0 ]; then
  echo "Execute as root"
  exit 1
fi

apt-get update -y
apt-get install -y openssh-server autossh socat ufw net-tools

echo "Mise en place du relais + pont SSH Airbus <--> OpenNebula"

# create user
if id "$RELAIS_USER" >/dev/null 2>&1; then
  echo "User $RELAIS_USER exists"
else
  adduser --disabled-password --gecos "" "$RELAIS_USER"
  echo "User $RELAIS_USER created"
fi

mkdir -p /home/${RELAIS_USER}/.ssh
touch /home/${RELAIS_USER}/.ssh/authorized_keys
chmod 700 /home/${RELAIS_USER}/.ssh
chmod 600 /home/${RELAIS_USER}/.ssh/authorized_keys
chown -R ${RELAIS_USER}:${RELAIS_USER} /home/${RELAIS_USER}/.ssh

echo "Place les clés publiques restreintes des clients dans /home/${RELAIS_USER}/.ssh/authorized_keys"
echo "Pour renforcer la sécurité, préfixer chaque clé avec "
echo "Exemple Airbus (permitopen=\"localhost:${AIRBUS_PORT}\"):"
echo 'no-pty,no-agent-forwarding,no-X11-forwarding,permitopen="localhost:2221",command="/bin/false" ssh-ed25519 AAAAC3 tunnel-to-airbus'
echo "Exemple OpenNebula (permitopen=\"localhost:${NEBULA_PORT}\"):"
echo 'no-pty,no-agent-forwarding,no-X11-forwarding,permitopen="localhost:2222",command="/bin/false" ssh-ed25519 AAAAC3 tunnel-to-opennebula'
echo "Ouvrir le port ssh (22) du firewall du Server relais"

#restreindre une clé pour qu’elle n’autorise que le forward TCP d’un port précis, édite /home/userA/.ssh/authorized_keys et préfixe la clé avec les options no-pty,no-agent-forwarding,no-X11-forwarding,permitopen="localhost:2201" (ex : pour l'étudiant Airbus). Ainsi la clé ne permettra pas d’ouvrir un shell interactif.
#Dans VM ubuntu faire sudo apt update
#sudo apt install -y openssh-server autossh
systemctl enable ssh
systemctl start ssh

#Créer services systemd socat pour ponts
cat > /etc/systemd/system/socat-opennebula.service <<EOF
[Unit]
Description=Socat pont Airbus -> OpenNebula (port ${BRIDGE_OPENNEBULA_PORT})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/socat TCP-LISTEN:${BRIDGE_NEBULA_PORT},reuseaddr,fork TCP:127.0.0.1:${NEBULA_PORT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/socat-airbus.service <<EOF
[Unit]
Description=Socat pont OpenNebula -> Airbus (port ${BRIDGE_AIRBUS_PORT})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/socat TCP-LISTEN:${BRIDGE_AIRBUS_PORT},reuseaddr,fork TCP:127.0.0.1:${AIRBUS_PORT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# 6. Activer et démarrer les services
systemctl daemon-reload
systemctl enable --now socat-opennebula.service socat-airbus.service

# 7. Configurer firewall de base
ufw allow 22/tcp
ufw allow from any to any port ${BRIDGE_NEBULA_PORT} proto tcp
ufw allow from any to any port ${BRIDGE_AIRBUS_PORT} proto tcp
ufw --force enable

# 8. Vérification
echo "Relais prêt, vérification des services et ports"
echo "Ports actifs"
ss -tlnp | grep -E "${AIRBUS_PORT}|${NEBULA_PORT}|${BRIDGE_AIRBUS_PORT}|${BRIDGE_NEBULA_PORT}" || true
echo
echo "Instructions :"
echo "* Les clients (Airbus/OpenNebula) doivent lancer leur tunnel inversé vers le relais"

echo "* Pour qu’Airbus atteigne OpenNebula : ssh -p ${BRIDGE_NEBULA_PORT} user_opennebula@RELAIS_IP"

echo "* Pour qu’OpenNebula atteigne Airbus : ssh -p ${BRIDGE_AIRBUS_PORT} user_airbus@RELAIS_IP"

echo "* Il faut s'assurer que les clés publiques des clients sont correctement ajoutées et restreintes"

#sudo netstat -tlnp | grep sshd affiche les ports écoutés par sshd sur le relais
#tcp 0 0 127.0.0.1:2221  ... sshd
#tcp 0 0 127.0.0.1:2222  ... sshd


# vers la VM OpenNebula faire ssh -p 2222 <user_opennebula>@localhost: delete

#Verfier que le tunnel fonctionne
#Dans /home/tunneluser/.ssh/authorized_keys, no-pty,no-agent-forwarding,no-X11-forwarding,permitopen="localhost:2221",command="/bin/false" ssh-ed25519 AAAAC3... tunnel-to-203.0.113.10:2221
#clé ne peut pas ouvrir un shell
#Elle ne peut qu’établir un tunnel -R 2221:localhost:22
