#!/usr/bin/env bash
# Client WireGuard - Côté OpenNebula

set -e -u -o pipefail

WG_IFACE="wg0"
WG_IP="10.10.10.2/24"
SERVER_IP="132.207.28.207"
SERVER_PORT="51820"
SERVER_WG_IP="10.10.10.1"
LOCAL_NET="132.202.0.0/16"
REMOTE_NET="10.2.0.0/16"

apt update && apt install -y wireguard

# Génération des clés
mkdir -p /etc/wireguard
cd /etc/wireguard
wg genkey | tee privatekey | wg pubkey > publickey

PRIV_KEY=$(cat privatekey)
echo "Il faut donner la clé publique OpenNebula à donner Airbus"
cat publickey

read -p "Merci de coller ici la clé publique Airbus" SERVER_KEY

# Création du fichier de config
cat > /etc/wireguard/${WG_IFACE}.conf <<EOF
[Interface]
Address = ${WG_IP}
PrivateKey = ${PRIV_KEY}

[Peer]
PublicKey = ${SERVER_KEY}
Endpoint = ${SERVER_IP}:${SERVER_PORT}
AllowedIPs = ${SERVER_WG_IP}/32, ${REMOTE_NET}
PersistentKeepalive = 25
EOF

# Activation du routage
sysctl -w net.ipv4.ip_forward=1
sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf

systemctl enable wg-quick@${WG_IFACE}
systemctl start wg-quick@${WG_IFACE}

echo "Client WireGuard côté OpenNebula configuré"
echo "L'interface ${WG_IFACE}, l'IP locale : ${WG_IP}, Endpoint : ${SERVER_IP}:${SERVER_PORT}"
echo "Merci de donner la clé publique ci-dessus à Airbus"
