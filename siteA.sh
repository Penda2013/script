#!/bin/bash
# Script d'installation et de configuration IPSec site-à-site
# Site A - côté serveur

# VARIABLES PERSONNALISABLES
REMOTE_NET="192.168.1.0/24"      # Réseau LAN du site B
LOCAL_NET="192.168.0.0/24"          # Réseau LAN du site A
PUBLIC_IP="132.28.207.207"       # IP publique du site A
PSK_FILE="/etc/ipsec.secrets"
CONF_FILE="/etc/ipsec.conf"
LOG_FILE="/var/log/ipsec_s.log"

echo "Installation et configuration IPSec StrongSwan"
sleep 1

# Vérification des privilèges root
if [[ $EUID -ne 0 ]]; then
  echo "Ce script doit être exécuté en tant que root"
  exit 1
fi

# Installation des paquets
echo "Installation de StrongSwan"
apt update -y && apt install -y strongswan strongswan-pki ufw

# Génération de la clé PSK aléatoire (modifiable via variable d'environnement PSK_ENV)
PSK="${PSK_ENV:-MaCleFixeEtSecrete123!}"
echo "Clé PSK utilisée : ${PSK}"


# Sauvegarde de la configuration existante
if [ -f "$CONF_FILE" ]; then
  mv $CONF_FILE ${CONF_FILE}.bak.$(date +%s)
fi
if [ -f "$PSK_FILE" ]; then
  mv $PSK_FILE ${PSK_FILE}.bak.$(date +%s)
fi

# Création du fichier /etc/ipsec.conf
cat <<EOF > $CONF_FILE

# Configuration IPSec Site-to-Site : Site A (serveur)

config setup
    charondebug="ike 2, cfg 2, knl 2, net 2, esp 2, dmn 2"

conn siteA-siteB
    keyexchange=ikev2
    authby=psk
    auto=add
    type=tunnel
    left=${PUBLIC_IP}
    leftsubnet=${LOCAL_NET}
    right=%any
    rightsubnet=${REMOTE_NET}
    ike=aes256-sha256-modp2048!
    esp=aes256-sha256-modp2048!
    dpdaction=restart
    dpddelay=30s
    dpdtimeout=120s
    ikelifetime=8h
    lifetime=1h
EOF

# Création du fichier /etc/ipsec.secrets
cat <<EOF > $PSK_FILE
${PUBLIC_IP} : PSK "${PSK}"
EOF

chmod 600 $PSK_FILE

# nftables + IP forwarding pour IPSec site-à-site

# Activer le forwarding IPv4 (immédiat + persistant)
sysctl -w net.ipv4.ip_forward=1
if ! grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf; then
  echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
fi

# Installer nftables si absent
apt-get update -y
apt-get install -y nftables

# Activer nftables au boot
systemctl enable nftables

# Sauvegarde ancienne conf si présente
if [ -f /etc/nftables.conf ]; then
  cp /etc/nftables.conf /etc/nftables.conf.bak.$(date +%Y%m%d-%H%M%S)
fi

# Générer la configuration nftables
cat >/etc/nftables.conf <<'EOF'
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
  chain input {
    type filter hook input priority 0;

    ct state established,related accept
    iif "lo" accept

    # IPSec : IKE/NAT-T (UDP 500/4500) et ESP
    udp dport {500,4500} accept
    meta l4proto esp accept

    # SSH d'admin (optionnel : restreindre par IP source si souhaité)
    tcp dport 22 accept

    # ICMP (diagnostic)
    icmp type { echo-request, echo-reply, destination-unreachable, time-exceeded } accept

    # drop par défaut
    counter drop
  }

  chain forward {
    type filter hook forward priority 0;

    ct state established,related accept

    # Autoriser flux entre les sous-réseaux via tunnel IPSec
    ip saddr 192.168.1.0/24 ip daddr 1192.168.0.0/24 accept
    ip saddr 192.168.0.0/24 ip daddr 192.168.1.0/24 accept

    # (Optionnel) restreindre à ICMP + SSH uniquement :
    # ip saddr 192.168.1.0/24 ip daddr 10.2.0.0/24 tcp dport 22 accept
    # ip saddr 192.168.0.0/24 ip daddr 192.168.1.0/24 tcp dport 22 accept
    # ip saddr 192.168.1.0/24 ip daddr 192.168.0.0/24 icmp type echo-request accept
    # ip saddr 192.168.0.0/24 ip daddr 192.168.1.0/24 icmp type echo-reply accept

    counter drop
  }

  chain output {
    type filter hook output priority 0;
    accept
  }
}
EOF

# Charger nftables
systemctl restart nftables

echo "nftables appliqué. Règles en place :"
nft list ruleset

# Activation et démarrage du service
systemctl enable strongswan
systemctl restart strongswan

# Vérification du service
echo "Vérification du statut IPSec"
ipsec statusall | tee -a $LOG_FILE

echo "ss -uln | grep -E ':(500|4500)\s'"
ss -uln | grep -E ':(500|4500)\s'

echo "ipsec statusall"
ipsec statusall

echo "nft list ruleset | sed -n '1,160p'"
nft list ruleset | sed -n '1,160p'


# Résumé de la configuration
cat <<EOF

IPSec (StrongSwan) installé et configuré sur Site A

- Adresse publique (left):  ${PUBLIC_IP}
- Réseau local (leftsubnet): ${LOCAL_NET}
- Réseau distant (rightsubnet): ${REMOTE_NET}
- Clé PSK : ${PSK}

Important:
Configuration du Site B avec ces paramètres :
   - Remote Gateway : ${PUBLIC_IP}
   - PSK : ${PSK}
   - Local network : ${REMOTE_NET}
   - Remote network : ${LOCAL_NET}

vérifier le tunnel avec :
  sudo ipsec statusall
  sudo ipsec listalgs
  sudo journalctl -u strongswan --no-pager | tail -30

Les logs sont dans : $LOG_FILE
EOF

echo " Faire sudo chmod +x /usr/local/bin/setup_ipsec_siteA.sh et sudo /usr/local/bin/ipsec_siteA.sh"