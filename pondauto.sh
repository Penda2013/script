#!/bin/bash
#!/usr/bin/env bash

set -euo pipefail

HOME=${HOME:-/root}
SOCKET_DIR="$HOME/.ssh/sockets"
mkdir -p "$SOCKET_DIR"
chmod 700 "$SOCKET_DIR"

# VPermet de verifier la presence autossh
if ! command -v autossh >/dev/null 2>&1; then
  echo "autossh n'est pas installe. Normalement l'installation doit etre lance avant et se fait automatiquement" >&2
  exit 1
fi

# Fonction pour extraire les informations SSH depuis ~/.ssh/config
extractfilessh() {
  local config_file="$HOME/.ssh/config"
  if [[ ! -f "$config_file" ]]; then
    return
  fi
  
  local current_host=""
  local current_user=""
  local current_port="22"
  local current_identity=""
  local current_hostname=""
  
  while IFS= read -r line; do
    line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    
    case "$line" in
      Host\ *)
        # Sauvegarder la configuration precedente si elle existe
        if [[ -n "$current_host" && -n "$current_hostname" ]]; then
          echo "${current_host}|${current_user}|${current_port}|${current_identity}|${current_hostname}"
        fi
        # Nouveau host
        current_host=$(echo "$line" | cut -d' ' -f2-)
        current_user=""
        current_port="22"
        current_identity=""
        current_hostname=""
        ;;
      HostName\ *)
        current_hostname=$(echo "$line" | cut -d' ' -f2-)
        ;;
      User\ *)
        current_user=$(echo "$line" | cut -d' ' -f2-)
        ;;
      Port\ *)
        current_port=$(echo "$line" | cut -d' ' -f2-)
        ;;
      IdentityFile\ *)
        current_identity=$(echo "$line" | cut -d' ' -f2-)
        ;;
    esac
  done < "$config_file"
  
  # Sauvegarder la derniere configuration
  if [[ -n "$current_host" && -n "$current_hostname" ]]; then
    echo "${current_host}|${current_user}|${current_port}|${current_identity}|${current_hostname}"
  fi
}

# Fonction pour detecter automatiquement les cles SSH disponibles
detectsshkeys() {
  local ssh_dir="$HOME/.ssh"
  local keys=""
  
  # Cles privees communes
  for key_pattern in "id_rsa" "id_ed25519" "id_ecdsa" "id_dsa"; do
    if [[ -f "$ssh_dir/$key_pattern" ]]; then
      keys="$keys $ssh_dir/$key_pattern"
    fi
  done
  
  # Cles avec extensions
  for key_file in "$ssh_dir"/*.pem "$ssh_dir"/*.ppk "$ssh_dir"/*.key; do
    if [[ -f "$key_file" ]]; then
      keys="$keys $key_file"
    fi
  done
  
  echo "$keys" | tr ' ' '\n' | grep -v '^$' | sort -u
}

# Fonction pour tester la connectivite avec authentification
testsshconnection() {
  local host="$1"
  local user="$2"
  local port="$3"
  local identity="$4"
  
  local ssh_opts="-o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no"
  
  if [[ -n "$identity" && -f "$identity" ]]; then
    ssh_opts="$ssh_opts -i \"$identity\""
  fi
  
  if [[ -n "$port" && "$port" != "22" ]]; then
    ssh_opts="$ssh_opts -p $port"
  fi
  
  # Test de connectivite SSH
  if ssh $ssh_opts -n "${user}@${host}" "echo 'SSH_OK'" >/dev/null 2>&1; then
    echo "true"
  else
    echo "false"
  fi
}

auto_detect() {
  echo "DeTECTION AUTOMATIQUE DES PLATEFORMES SSH"
  
  local platformsfound=0
  local sshconfigs=""
  local availablekeys=""
  
  # Extraire les configurations SSH
  sshconfigs=$(extractfilessh)
  
  # Détecter les clés disponibles
  availablekeys=$(detectsshkeys)
  
  echo "Configurations SSH trouvees:"
  echo "$sshconfigs" | while IFS='|' read -r host user port identity hostname; do
    if [[ -n "$host" && -n "$hostname" ]]; then
      echo "  Host: $host -> $hostname (User: ${user:-$(whoami)}, Port: ${port:-22})"
      
      # Tester avec l'utilisateur configure ou par defaut
      local test_user="${user:-$(whoami)}"
      local test_port="${port:-22}"
      
      # Tester avec la cle configuree
      if [[ -n "$identity" && -f "$identity" ]]; then
        if [[ "$(testsshconnection "$hostname" "$test_user" "$test_port" "$identity")" == "true" ]]; then
          echo "La connectivite est OK avec la cle: $identity"
          platformsfound=$((platforms_found + 1))
          continue
        fi
      fi
      
      # Tester avec les cles disponibles
      local connected=false
      for key in $availablekeys; do
        if [[ "$(testsshconnection "$hostname" "$test_user" "$test_port" "$key")" == "true" ]]; then
          echo "La connectivite est OK avec la cle: $key"
          platformsfound=$((platforms_found + 1))
          connected=true
          break
        fi
      done
      
      if [[ "$connected" == "false" ]]; then
        echo "Aucune cle n'est valide pour $hostname"
      fi
    fi
  done
  
  echo ""
  echo "Les cles SSH sont disponibles:"
  for key in $availablekeys; do
    echo "  - $key"
  done
  
  echo ""
  echo "Les 2 interfaces sont detectees et accessibles: $platformsfound"
  
  if [[ $platformsfound -ge 2 ]]; then
    echo "Suffisamment de plateformes détectées pour créer un pont SSH"
    return 0
  else
    echo "Pas assez de plateformes accessibles (minimum 2 requis)"
    return 1
  fi
}

# Fonction pour créer automatiquement des tunnels entre plateformes détectées
createtunnels() {
  echo "Creation des tunnels de facon automatique"
  
  local sshconfigs=$(extractfilessh)
  local platformcount=0
  local platforms=()
  
  # Collecter les plateformes accessibles
  echo "$sshconfigs" | while IFS='|' read -r host user port identity hostname; do
    if [[ -n "$host" && -n "$hostname" ]]; then
      local test_user="${user:-$(whoami)}"
      local test_port="${port:-22}"
      
      # Tester la connectivité
      if [[ "$(testsshconnection "$hostname" "$test_user" "$test_port" "$identity")" == "true" ]]; then
        platforms+=("$hostname|$test_user|$test_port|$identity")
        platformcount=$((platformcount + 1))
      fi
    fi
  done
  
  if [[ $platformcount -lt 2 ]]; then
    echo "Nous n'avons pas encore detecte les plateformes"
    return 1
  fi
  
  echo "Creation de tunnels entre $platformcount"
  
  # Creation des tunnels bidirectionnels
  for i in "${!platforms[@]}"; do
    for j in "${!platforms[@]}"; do
      if [[ $i -ne $j ]]; then
        IFS='|' read -r host1 user1 port1 key1 <<< "${platforms[$i]}"
        IFS='|' read -r host2 user2 port2 key2 <<< "${platforms[$j]}"
        
        local tunnel_port=$((8000 + i * 10 + j))
        
        echo "Creation tunnel: $host1:$tunnel_port -> $host2:22"
        
        # Créer le tunnel (en arrière-plan)
        local ssh_opts1="-o ConnectTimeout=5 -o BatchMode=yes"
        [[ -n "$key1" && -f "$key1" ]] && ssh_opts1="$ssh_opts1 -i \"$key1\""
        [[ -n "$port1" && "$port1" != "22" ]] && ssh_opts1="$ssh_opts1 -p $port1"
        
        ssh $ssh_opts1 -f -N -L "$tunnel_port:$host2:22" "${user1}@${host1}" 2>/dev/null || {
          echo "Echec tunnel $host1 -> $host2"
        }
      fi
    done
  done
  
  echo "Tunnels automatiques crees avec succes wouahh"
  echo "Vous devez utiliser svp 'ssh -p <port> localhost' pour acceder aux 2 plateformes"
}

# Permet de recuperer les configurations depuis ~/.ssh/config, known_hosts et /etc/hosts
user_collect() {
  local list=""
  [ -f "$HOME/.ssh/config" ] && list="$list $(awk '/^Host /{for(i=2;i<=NF;i++) print $i}' "$HOME/.ssh/config" | grep -vE '^\*|^Proxy' || true)"
  [ -f "$HOME/.ssh/known_hosts" ] && list="$list $(awk '{print $1}' "$HOME/.ssh/known_hosts" | sed 's/,.*//' | sed 's/^\[//;s/\].*//' )"
  [ -f /etc/hosts ] && list="$list $(awk '/^[^#]/ && NF>=2 { for(i=2;i<=NF;i++) print $i }' /etc/hosts)"
  printf "%s\n" $list | sed '/^$/d' | sort -u
}

# Permet de tester la reachabilite port 22 (preference nc, fallback /dev/tcp)
test_ssh_connectivity() {
  local host="$1"
  if command -v nc >/dev/null 2>&1; then
    nc -z -w2 "$host" 22 >/dev/null 2>&1
    return $?
  else
    # bash /dev/tcp fallback
    (echo > /dev/tcp/"$host"/22) >/dev/null 2>&1
    return $?
  fi
}

# Permet de detecter les hotes SSH
hosts_detect_hosts() {
  local users host found=""
  users=$(user_collect)
  for host in $users; do
    # Skip patterns invalides
    case "$host" in
      *\**|*\,*|*:* ) continue ;;
    esac
    if test_ssh_connectivity "$host"; then
      found="$found $host"
      # Stop apres deux hotes trouves
      if [ "$(printf "%s\n" $found | wc -w)" -ge 2 ]; then
        break
      fi
    fi
  done
  printf "%s\n" $found
}

start_tunnels_start() {
  local hosts idx host port_local_port
  hosts=$(hosts_detect_hosts)
  if [ -z "$hosts" ]; then
    echo "Aucun hote SSH detecte reachable sur le port 22 (recherche dans ~/.ssh/config, known_hosts, /etc/hosts)" >&2
    exit 1
  fi

  idx=1
  for host in $hosts; do
    port_local_port=$((2200 + idx))
    echo "Demarrage autossh -> $host (local port: $port_local_port)"
    # Autossh expose le port 22 du host distant (localhost sur la machine distante) sur localhost:port_local_port
    autossh -M 0 -f -N \
      -o "ServerAliveInterval=30" -o "ServerAliveCountMax=3" -o "ExitOnForwardFailure=yes" \
      -L "${port_local_port}:localhost:22" "$host" || echo "Erreur autossh vers $host a echoue" >&2
    echo "$host -> localhost:$port_local_port" >> /tmp/sshtunnel-mapping
    idx=$((idx + 1))
  done

  echo "Pont ssh demarres avec succes, acceder aux hotes via ssh -p <port> localhost"
  printf "Mapping actuel \n"
  cat /tmp/sshtunnel-mapping || true
}

stop_tunnels_stop() {
  echo "Arret du pont ssh lances par ce script (cherche processus autossh avec -L localhost:22)"
  # Tuer les tunnels ssh qui ont une redirection -L vers localhost:22
  pids=$(pgrep -f "autossh.*-L [0-9]*:localhost:22" || true)
  if [ -n "$pids" ]; then
    echo "Killing: $pids"
    kill $pids || true
  else
    echo "Aucun ssh identifie."
  fi
  rm -f /tmp/sshtunnel-mapping
}


case "${1:-start}" in
  start) 
    echo "Demarrage des tunnels"
    start_tunnels_start 
    ;;
  stop) 
    echo "Arret des tunnels"
    stop_tunnels_stop 
    ;;
  restart) 
    echo "Redeemarrage "
    stop_tunnels_stop
    sleep 1
    start_tunnels_start 
    ;;
  tunnel)
    echo "recherche avances"
    handleTunnelCommand "${@}"
    ;;
  auto-detect)
    echo "detection automatique pour les 2"
    auto_detect
    ;;
  auto-tunnel)
    echo "Creation"
    createtunnels
    ;;
  help|--help|-h)
    echo "help"
    echo ""
    echo "USAGE:"
    echo "  $0 {start|stop|restart|tunnel|auto-detect|auto-tunnel|help}"
    echo ""
    echo "COMMANDES:"
    echo "  start        - Demarrer les tunnels automatiques avec autossh"
    echo "  stop         - Arreter les tunnels automatiques"
    echo "  restart      - Redemarrer les tunnels automatiques"
    echo "  tunnel       - Systeme de tunnels SSH avancés avec contrôle précis"
    echo "  auto-detect  - Detecter automatiquement toutes les plateformes SSH accessibles"
    echo "  auto-tunnel  - Creer automatiquement des tunnels entre plateformes détectees"
    echo "  help         - Afficher cette aide"
    echo ""
    echo "EXEMPLES:"
    echo "  $0 start                                   
    echo "  $0 auto-detect                              
    echo "  $0 auto-tunnel                              
    echo "  $0 tunnel --help                           
    echo "  $0 tunnel --configure --remote-user root --remote-host server.com"
    echo "  $0 tunnel --local-port 8080 --remote-port 9090 --local-to-remote --remote-user root --remote-host server.com"
    ;;
  *) 
    echo "Sinon la commande n'est pas reconnue"
    echo "Usage: $0 {start|stop|restart|tunnel|auto-detect|auto-tunnel|help}"
    echo "Utilisez '$0 help' pour plus d'informations"
    exit 2 
    ;;
esac

exit 0



