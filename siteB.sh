#!/bin/bash
# Script d'installation et de configuration IPSec site-à-site
# pfSense (Site B) - côté initiateur

SITEA_IP="132.28.207.207"
SITEA_SUBNET="192.168.0.0/24"
SITEB_SUBNET="192.168.1.0/24"
PSK="${PSK_ENV:-MaCleFixeEtSecrete123!}"

CONF_FILE="/usr/local/etc/ipsec.conf"
SECRETS_FILE="/usr/local/etc/ipsec.secrets"
LOG_FILE="/var/log/ipsec_setup.log"

if [ "$(id -u)" -ne 0 ]; then
  echo "Ce script doit être exécuté en tant que root."
  exit 1
fi

timestamp=$(date +%Y%m%d-%H%M%S)
for f in $CONF_FILE $SECRETS_FILE; do
  [ -f "$f" ] && cp "$f" "$f.bak.$timestamp"
done

cat > $CONF_FILE <<EOF
config setup
    charondebug="ike 2, cfg 2, knl 2, net 2, esp 2, dmn 2"

conn siteB-siteA
    keyexchange=ikev2
    authby=psk
    auto=start
    type=tunnel
    left=%any
    leftid=%any
    leftsubnet=${SITEB_SUBNET}
    right=${SITEA_IP}
    rightsubnet=${SITEA_SUBNET}
    ike=aes256-sha256-modp2048!
    esp=aes256-sha256-modp2048!
    dpdaction=restart
    dpddelay=30s
    dpdtimeout=120s
    ikelifetime=8h
    lifetime=1h
EOF

cat > $SECRETS_FILE <<EOF
%any ${SITEA_IP} : PSK "${PSK}"
EOF

chmod 600 $SECRETS_FILE

if ! grep -q "strongswan_enable" /etc/rc.conf.local 2>/dev/null; then
  echo 'strongswan_enable="YES"' >> /etc/rc.conf.local
fi

ipsec stop >/dev/null 2>&1
sleep 2
ipsec start

sleep 3
STATUS=$(ipsec status | grep ESTABLISHED)

if [ -n "$STATUS" ]; then
  echo "Tunnel IPSec établi avec succès."
else
  echo "Le tunnel n'est pas encore établi. Vérifie la connectivité et la clé PSK."
fi

echo "$(date) : IPSec configuré - SiteB <-> SiteA (${SITEA_IP})" >> $LOG_FILE

echo "Configuration IPSec site-à-site appliquée"
echo "Fichier conf : $CONF_FILE"
echo "Fichier clé  : $SECRETS_FILE"
echo "Tunnel vers  : $SITEA_IP"
echo "LAN local    : $SITEB_SUBNET"
echo "LAN distant  : $SITEA_SUBNET"
echo "Service auto : activé au démarrage"
echo "Vérifie le tunnel avec : ipsec statusall"

echo "chmod +x /root/siteB.sh et sh /root/siteB.sh"

echo "ipsec statusall et ping -S 192.168.1.10 192.168.0.3 depuis Site B"


