#!/bin/bash
set -e -u -o pipefail

# IP/WAN ou FQDN du PfSense Site B
SITEB_WAN="10.30.192.4"

# Sous-réseau des VMs/site A ( exposer via le tunnel)
SITEA_SUBNET="192.168.0.0/24"

# IP locale de l'interface d'accès aux workzones
SITEA_IFACE_IP="10.2.0.30"

# Sous-réseau du Site B
SITEB_SUBNET="192.168.1.0/24"

PSK="${PSK_ENV:-InconnuKeyModify2025!}"

CONF_FILE="/etc/ipsec.conf"
SECRETS_FILE="/etc/ipsec.secrets"
NFT_CONF="/etc/nftables.conf"
LOG_FILE="/var/log/ipsec_setup.log"
BACKUP_TS=$(date +%Y%m%d-%H%M%S)

if [ "$(id -u)" -ne 0 ]; then
  echo "Ce script doit être exécuté en root."
  exit 1
fi

echo "Sauvegarde des fichiers existants "
[ -f "$CONF_FILE" ] && cp "$CONF_FILE" "${CONF_FILE}.bak.$BACKUP_TS"
[ -f "$SECRETS_FILE" ] && cp "$SECRETS_FILE" "${SECRETS_FILE}.bak.$BACKUP_TS"
[ -f "$NFT_CONF" ] && cp "$NFT_CONF" "${NFT_CONF}.bak.$BACKUP_TS"

echo "Écriture du fichier /etc/ipsec.conf"
cat > "$CONF_FILE" <<EOF
config setup
    charondebug="all"

conn siteA-siteB
    keyexchange=ikev2
    authby=psk
    auto=start
    type=tunnel
    left=%any
    leftid=%any
    leftsourceip=${SITEA_IFACE_IP}
    leftsubnet=${SITEA_SUBNET}
    right=${SITEB_WAN}
    rightid=%any
    rightsubnet=${SITEB_SUBNET}
    ike=aes256-sha256-modp2048!
    esp=aes256-sha256-modp2048!
    dpdaction=restart
    dpddelay=30s
    dpdtimeout=120s
    ikelifetime=8h
    lifetime=1h
    nat_traversal=yes
EOF

echo "Écriture de /etc/ipsec.secrets"
cat > "$SECRETS_FILE" <<EOF
%any ${SITEB_WAN} : PSK "${PSK}"
EOF
chmod 600 "$SECRETS_FILE"

echo "Configuration nftables (autorisation IKE/NAT-T, ESP et forwarding)"
cat > "$NFT_CONF" <<'EOF'
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;
    ct state established,related accept
    iif "lo" accept

    # Autoriser SSH
    tcp dport 22 accept

    # IKE / NAT-T
    udp dport {500,4500} accept
    # ESP
    ip protocol esp accept

    # ICMP
    icmp type { echo-request, echo-reply, destination-unreachable, time-exceeded } accept

    counter drop
  }

  chain forward {
    type filter hook forward priority 0; policy drop;
    ct state established,related accept

    # Autoriser trafic entre les deux sous-réseaux via le tunnel
    ip saddr 192.168.0.0/24 ip daddr 192.168.1.0/24 accept
    ip saddr 192.168.1.0/24 ip daddr 192.168.0.0/24 accept

    counter drop
  }

  chain output {
    type filter hook output priority 0; policy accept;
  }
}
EOF

echo "Activer IP forwarding"
sysctl -w net.ipv4.ip_forward=1
grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf

echo "Chargement nftables"

nft -c -f "$NFT_CONF"
systemctl enable nftables 2>/dev/null || true
systemctl restart nftables

echo "demarrage StrongSwan"
# strongswan est installé
if ! command -v ipsec >/dev/null 2>&1; then
  echo "Warning: la commande 'ipsec' n'est pas trouvée. Vérifie que strongswan est installé."
else
  systemctl enable strongswan-starter 2>/dev/null || true
  systemctl restart strongswan-starter
fi

sleep 3
echo " Vérification rapide "
echo "PSK utilisée : ${PSK}"
echo "ipsec status"
ipsec status 2>/dev/null || true

echo "$(date) : siteA_i executed" >> "$LOG_FILE"

echo "Vérifications recommandées"
echo "  journalctl -u strongswan-starter -f"
echo "  sudo nft list ruleset"
echo "  sudo ss -lunp | grep -E ':(500|4500)'"
echo "  ping 192.168.1.10  # depuis une VM du site A vers une VM du site B"
echo "  ipsec statusall"
echo "Configuration terminée. Voir le fichier de log : $LOG_FILE"


