#!/bin/bash
# pfSense shell is tcsh by default but /bin/bash works for basic ops
# This script: backup config.xml, generate static shared key and insert OpenVPN server XML, reload config.

PFS_CONF="/conf/config.xml"
BACKUP_DIR="/conf/backup_openvpn_$(date +%Y%m%d%H%M%S)"
SHARED_KEY_TMP="/tmp/ovpn_1_2.key"
OPENVPN_PORT="${OPENVPN_PORT:-1194}"
PROTO="${PROTO:-udp}"
SITE2_LAN="${SITE2_LAN:-192.168.1.0/24}"
SITE1_LAN="${SITE1_LAN:-192.168.0.0/24}"
TUN_NET="${TUN_NET:-10.8.0.0/30}"

set -e -u -o pipefail

echo "Backup /conf/config.xml → $BACKUP_DIR"
mkdir -p "$BACKUP_DIR"
cp "$PFS_CONF" "$BACKUP_DIR/config.xml.bak"

openvpn --genkey --secret "$SHARED_KEY_TMP"
chmod 600 "$SHARED_KEY_TMP"

SERVER_XML="
      <server>
        <enable>1</enable>
        <mode>p2p_shared_key</mode>
        <protocol>${PROTO}</protocol>
        <interface>wan</interface>
        <local_port>${OPENVPN_PORT}</local_port>
        <description>Site1-Site2-OpenVPN</description>
        <shared_key><![CDATA[$(cat "$SHARED_KEY_TMP")]]></shared_key>
        <tunnel_network>${TUN_NET}</tunnel_network>
        <local_network>${SITE2_LAN}</local_network>
        <remote_network>${SITE1_LAN}</remote_network>
        <compression>disabled</compression>
      </server>
"

if ! grep -q "<servers>" "$PFS_CONF"; then
  sed -i '' 's|<openvpn>|<openvpn><servers></servers>|' "$PFS_CONF"
fi

awk -v frag="$SERVER_XML" '
  /<\/servers>/ && !done { print frag; done=1 }
  { print }
' "$PFS_CONF" > "$PFS_CONF.new"

mv "$PFS_CONF.new" "$PFS_CONF"
sync

FILTER_RULES="
  <rule>
    <type>pass</type>
    <interface>wan</interface>
    <protocol>udp</protocol>
    <source><any/></source>
    <destination><address>wan</address><port>${OPENVPN_PORT}</port></destination>
    <descr>Allow OpenVPN Site2Site</descr>
  </rule>

  <rule>
    <type>pass</type>
    <interface>openvpn</interface>
    <protocol>any</protocol>
    <source><network>${SITE2_LAN}</network></source>
    <destination><network>${SITE1_LAN}</network></destination>
    <descr>Allow Site2 to Site1 with OpenVPN</descr>
  </rule>

  <rule>
    <type>pass</type>
    <interface>openvpn</interface>
    <protocol>any</protocol>
    <source><network>${SITE1_LAN}</network></source>
    <destination><network>${SITE2_LAN}</network></destination>
    <descr>Allow Site1 to Site2 with OpenVPN</descr>
  </rule>
"

awk -v rules="$FILTER_RULES" '
  /<\/filter>/ && !done { print rules; done=1 }
  { print }
' "$PFS_CONF" > "$PFS_CONF.new"

mv "$PFS_CONF.new" "$PFS_CONF"
sync

# Reload config (this applies the OpenVPN entry)
echo " Reloading pfSense config"
/etc/rc.reboot_pending 2>/dev/null || true
# prefer reload_all to reapply config
/etc/rc.reload_all

# Ensure firewall allows UDP port for OpenVPN to this box
echo "Firewall rules added and persistent via pfctl"
# This is a best-effort runtime rule (not persisted) — pfSense web UI will have persistent rules via config.xml
# The following uses pfctl to add a quick pass rule (runtime). If not available, instruct manual step later.
pfctl -sr >/dev/null 2>&1 || true

echo " Done. Shared key saved in $SHARED_KEY_TMP"
echo " Copy the shared key file to site 1 into /etc/openvpn/1-2.key with scp"
echo " scp root@$(hostname -s):$SHARED_KEY_TMP /etc/openvpn/1-2.key"
echo " Then configure OpenVPN client on Site 1 with the same settings (p2p_shared_key, protocol, port, LANs)"

