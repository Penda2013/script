#!/bin/bash
set -e -u -o pipefail

PFSENSE_WAN_IP="${PFSENSE_WAN_IP:-10.30.192.4}"
OPENVPN_PORT="${OPENVPN_PORT:-1194}"
PROTO="${PROTO:-udp}"
TUN_IP_LOCAL="${TUN_IP_LOCAL:-10.8.0.2}"
TUN_IP_REMOTE="${TUN_IP_REMOTE:-10.8.0.1}"
TUN_NET="${TUN_NET:-10.8.0.0/30}"
SITEB_LAN="${SITEB_LAN:-192.168.1.0/24}"
CLIENT_CONF="/etc/openvpn/1-2.conf"
SHARED_KEY_FILE="/etc/openvpn/1-2.key"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root"
  exit 1
fi

echo "Installing openvpn"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y openvpn

echo "Waiting for shared key content to be provided"
# user must paste the shared key into the file or we try to fetch from /tmp (copied from pfSense step)
if [ ! -s "$SHARED_KEY_FILE" ]; then
  echo "Place the OpenVPN static key (shared) in $SHARED_KEY_FILE"
  read -r _
fi

if [ ! -s "$SHARED_KEY_FILE" ]; then
  echo "ERROR: shared key file $SHARED_KEY_FILE is empty, Aborting"
  exit 2
fi

echo "Writing OpenVPN client config to $CLIENT_CONF"
cat > "$CLIENT_CONF" <<EOF
client
dev tun
proto ${PROTO}
remote ${PFSENSE_WAN_IP} ${OPENVPN_PORT}
nobind
persist-key
persist-tun
topology p2p
# tun IPs P2P
ifconfig ${TUN_IP_LOCAL} ${TUN_IP_REMOTE}
# route towards B LAN over the tunnel
route ${SITEB_LAN} 255.255.255.0
secret ${SHARED_KEY_FILE}
verb 3
mute 20
EOF

chmod 600 "$SHARED_KEY_FILE" "$CLIENT_CONF"

echo "Enabling systemd service"
# create a simple systemd unit wrapper if distribution uses openvpn@.service
if systemctl list-unit-files | grep -q '^openvpn@'; then
  cp "$CLIENT_CONF" /etc/openvpn/1-2.conf
  systemctl enable openvpn@1-2
  systemctl restart openvpn@1-2
else
  # fallback: start openvpn pointing to config file
  systemctl enable openvpn.service 2>/dev/null || true
  # start a dedicated instance
  nohup openvpn --config "$CLIENT_CONF" >/var/log/openvpn-1.log 2>&1 &
fi

echo "  Done Check status:"
echo "  systemctl status openvpn@1-2 || tail -n 200 /var/log/openvpn-1.log"
echo "  ip route show"
echo "  ip addr show dev tun0 or ip addr show tun0"
echo "  ping -c3 ${TUN_IP_REMOTE}"
echo "  ping -c3 $(echo ${SITEB_LAN} | cut -d. -f1-3).1  # ping B LAN gateway"
echo "  ping 10.8.0.1 and ping 192.168.1.1"
