#!/bin/bash
#!/usr/bien/env bash
#Nebula.sh

set -euo pipefail

# Prépare la VM OpenNebula pour accepter un reverse-SSH depuis Airbus.
# sudo bash opennebula.sh

USER_REV="revssh"
SSH_DIR="/home/${USER_REV}/.ssh"
SSHD_CONF="/etc/ssh/sshd_config"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root: sudo $0"
  exit 1
fi

# Créer l'utilisateur si absent
if id "$USER_REV" &>/dev/null; then
  echo "Utilisateur $USER_REV existe"
else
  adduser --disabled-password --gecos "" "$USER_REV"
  echo "Utilisateur $USER_REV créé"
fi

mkdir -p "$SSH_DIR"
chown "$USER_REV:$USER_REV" "$SSH_DIR"
chmod 700 "$SSH_DIR"

touch "${SSH_DIR}/authorized_keys"
chown "$USER_REV:$USER_REV" "${SSH_DIR}/authorized_keys"
chmod 600 "${SSH_DIR}/authorized_keys"

# Autoriser les remote forwards et binding sur toutes les interfaces
grep -q '^AllowTcpForwarding' "$SSHD_CONF" && sed -i '/^AllowTcpForwarding/c\AllowTcpForwarding yes' "$SSHD_CONF" || echo "AllowTcpForwarding yes" >> "$SSHD_CONF"
grep -q '^GatewayPorts' "$SSHD_CONF" && sed -i '/^GatewayPorts/c\GatewayPorts yes' "$SSHD_CONF" || echo "GatewayPorts yes" >> "$SSHD_CONF"
# Réduire l'accès root si necessaire
#grep -q '^PermitRootLogin' "$SSHD_CONF" && sed -i '/^PermitRootLogin/c\PermitRootLogin no' "$SSHD_CONF" || echo "PermitRootLogin no" >> "$SSHD_CONF"

# Redémarrer le service SSH
if command -v systemctl >/dev/null 2>&1; then
  systemctl restart ssh || systemctl restart sshd || true
else
  service ssh restart || service sshd restart || true
fi

echo
echo "Prêt sur OpenNebula"
echo "Ajout de la clé publique d'Airbus dans ${SSH_DIR}/authorized_keys"
echo "  echo 'PASTE_PUBLIC_KEY_FROM_AIRBUS' | sudo tee -a ${SSH_DIR}/authorized_keys"
echo "  sudo chown ${USER_REV}:${USER_REV} ${SSH_DIR}/authorized_keys && sudo chmod 600 ${SSH_DIR}/authorized_keys"
echo
echo "Après ajout de la clé, Airbus pourra ouvrir un reverse-tunnel vers cette VM."
#echo "Commande côté Airbus :"
#echo "  ssh -N -R 2222:localhost:22 ${USER_REV}@<IP_DE_LA_VM_OPENNEBULA>"
echo "Nous allons inverser le tunnel pour accéder à la VM OpenNebula depuis Airbus. Commande côté OpenNebula"
echo "  ssh -N -R 2222:localhost:22 ${USER_REV}@<IP_PUBLIQUE_AIRBUS>"
#echo  "Puis, pour se connecter à la VM OpenNebula  depuis Airbus :"
echo  "Puis, pour se connecter à la VM Airbus depuis OpenNebula "
echo "  ssh -p 2222 localhost"  
echo
echo "Assurez-vous que le port 2222 est ouvert dans le firewall de la VM Airbus"

