#!/bin/bash

# L'objectif est de créer automatiquement un utilisateur sur Airbus et configurer l’accès SSH sécurisé
# Et aussi de genérer la clé SSH sur OpenNebula et autoriser l’accès sécurisé et le tunneling

set -e
REMOTE_HOST="${1}"         # Adresse publique ou IP Airbus
REMOTE_USER="root"         # Utilisateur admin ayant accès SSH à Airbus
NEW_USER="airbus_cr" # Utilisateur à créer sur Airbus
# Chemin et nom de la clé SSH locale
KEY_DIR="$HOME/.ssh"
KEY_NAME="id_airbus_cr"
LOCAL_PUB_KEY="$KEY_DIR/${KEY_NAME}.pub"
LOCAL_PRIV_KEY="$KEY_DIR/${KEY_NAME}"

if [[ -z "$REMOTE_HOST" ]]; then
    echo "Usage: $0 IP publique airbus"
    exit 1
fi

echo " Genération de la clé SSH locale"

mkdir -p "$KEY_DIR"
chmod 700 "$KEY_DIR"

if [[ ! -f "$LOCAL_PRIV_KEY" ]]; then
    ssh-keygen -t rsa -b 4096 -f "$LOCAL_PRIV_KEY" -N "" -C "airbus_cr"
    echo "Clé SSH générée : $LOCAL_PUB_KEY"
else
    echo "Clé SSH déjà existante : $LOCAL_PUB_KEY"
fi

echo
echo " Creation de l'utilisateur sur Airbus et configuration SSH"

ssh -i "$LOCAL_PRIV_KEY" -o StrictHostKeyChecking=no "$REMOTE_USER@$REMOTE_HOST" bash -s <<'EOF'
set -e
USER_NAME="user_nebula"  # Remplacer par le nom d'utilisateur souhaité
PUB_KEY="/tmp/nebula_key.pub"

# Créer l'utilisateur s'il n'existe pas
if id "$USER_NAME" &>/dev/null; then
    echo "L'utilisateur $USER_NAME existe déjà"
else
    echo "Création de l'utilisateur $USER_NAME..."
    adduser --disabled-password --gecos "" "$USER_NAME"
    usermod -aG sudo "$USER_NAME"
fi

# Préparer le dossier .ssh
sudo -u "$USER_NAME" mkdir -p /home/"$USER_NAME"/.ssh
sudo -u "$USER_NAME" chmod 700 /home/"$USER_NAME"/.ssh

# Créer le fichier authorized_keys vide s'il n'existe pas
sudo -u "$USER_NAME" touch /home/"$USER_NAME"/.ssh/authorized_keys
sudo -u "$USER_NAME" chmod 600 /home/"$USER_NAME"/.ssh/authorized_keys

# Sauvegarde de la config SSH
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak

# Active le forwarding et gateway
sed -i '/^AllowTcpForwarding/c\AllowTcpForwarding yes' /etc/ssh/sshd_config || echo "AllowTcpForwarding yes" >> /etc/ssh/sshd_config
sed -i '/^GatewayPorts/c\GatewayPorts yes' /etc/ssh/sshd_config || echo "GatewayPorts yes" >> /etc/ssh/sshd_config
sed -i '/^PermitRootLogin/c\PermitRootLogin no' /etc/ssh/sshd_config || echo "PermitRootLogin no" >> /etc/ssh/sshd_config
sed -i '/^PasswordAuthentication/c\PasswordAuthentication no' /etc/ssh/sshd_config || echo "PasswordAuthentication no" >> /etc/ssh/sshd_config

systemctl restart ssh
EOF

echo "Envoi automatique de la clé publique sur CR1"

# Copie la cle publique générée dans authorized_keys de user_nebula sur Airbus
PUB_KEY_CONTENT=$(cat "$LOCAL_PUB_KEY")
ssh -i "$LOCAL_PRIV_KEY" -o StrictHostKeyChecking=no "$REMOTE_USER@$REMOTE_HOST" "echo '$PUB_KEY_CONTENT' | sudo tee -a /home/airbus_cr/.ssh/authorized_keys >/dev/null && sudo chown airbus_cr:airbus_cr /home/airbus_cr/.ssh/authorized_keys"
#ssh -i "$LOCAL_PRIV_KEY" -o StrictHostKeyChecking=no "$REMOTE_USER@$REMOTE_HOST" "sudo chown -R airbus_cr:airbus_cr /home/airbus_cr/.ssh && sudo chmod 700 /home/airbus_cr/.ssh && sudo chmod 600 /home/airbus_cr/.ssh/authorized_keys"

echo "Test de connexion"
ssh -i "$LOCAL_PRIV_KEY" -o StrictHostKeyChecking=no "airbus_cr@$REMOTE_HOST" "hostname && echo 'Connexion SSH réussie'"

echo
echo "  Utilisateur créé : airbus_cr"
echo "  Clé SSH : $LOCAL_PRIV_KEY"
echo "  Hôte distant : $REMOTE_HOST"
echo "  ssh -i $LOCAL_PRIV_KEY airbus_cr@$REMOTE_HOST"
echo
echo "Tout est configure avec forwarding et acces securise"


#Dans VM OpenNebula, faire ces commandes
#chmod +x connexion.sh
#./connexion.sh IP publique Airbus

#Dans VM Airbus, faire avec le nom de l’utilisateur et le chemin de la clé publique de la VM OpenNebula
#chmod +x connexion.sh
#./connexion.sh user_nebula cle publique VM OpenNebula
