#!/usr/bin/env bash
# Serveur WireGuard - Côté Airbus

set -e -u -o pipefail

WG_IFACE="wg0"
WG_IP="10.10.10.1/24"
WG_PORT="51820"
WG_PEER_IP="10.10.10.2"
WG_PEER_NET="132.202.0.0/16"
LOCAL_NET="10.2.0.0/16"

apt update && apt install -y wireguard

# Génération des clés
mkdir -p /etc/wireguard
cd /etc/wireguard
wg genkey | tee privatekey | wg pubkey > publickey

PRIV_KEY=$(cat privatekey)
echo "Merci de donner la clé publique Airbus à OpenNebula svp"
cat publickey

read -p "Merci de coller ici la clé publique envoyee par la VM OpenNebula svp" PEER_KEY

# Création du fichier de config
cat > /etc/wireguard/${WG_IFACE}.conf <<EOF
[Interface]
Address = ${WG_IP}
ListenPort = ${WG_PORT}
PrivateKey = ${PRIV_KEY}
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

[Peer]
PublicKey = ${PEER_KEY}
AllowedIPs = ${WG_PEER_IP}/32, ${WG_PEER_NET}
EOF

# Activation du routage IP
sysctl -w net.ipv4.ip_forward=1
sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf

systemctl enable wg-quick@${WG_IFACE}
systemctl start wg-quick@${WG_IFACE}

echo "Serveur WireGuard côté Airbus configuré."
echo "L'interface : ${WG_IFACE}, l'IP locale : ${WG_IP}, Port : ${WG_PORT}"
echo "Merci de donner la clé publique ci-dessus à OpenNebula svp"
