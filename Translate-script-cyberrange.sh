#!/bin/bash
#!/usr/bin/env bash
# Script pour etablir un pont SSH, faciliter l'import/export de VM et orchestrer les ressources entre deux Cyber Range
# Permet de detecter automatiquement les connexions SSH et de creer un pont entre les 2

apt-get update
apt-get install -y autossh netcat python3-flask
systemctl stop autossh-tunnel.service 2>/dev/null

# Permet de creer le fichier de service systemd
cat <<EOF > /etc/systemd/system/autossh-tunnel.service
EOF

systemctl daemon-reload
systemctl enable autossh-tunnel.service

# Nous avons cree une fonction utilitaire qui est necessaire pour le systeme de tunnels
EmptyString() {
    local -r string="${1}"
    if [[ "$(trimString "${string}")" = '' ]]
    then
        echo 'true'
    else
        echo 'false'
    fi
}

trimString() {
    local -r string="${1}"
    sed 's,^[[:blank:]]*,,' <<< "${string}" | sed 's,[[:blank:]]*$,,'
}

formatPath() {
    local -r path="${1}"
    if [[ "$(EmptyString "${path}")" = 'true' ]]
    then
        echo ''
        return
    fi
    local -r trimmedPath="$(trimString "${path}")"
    local -r firstCharacter="$(trimString "$(cut -c1 <<< "${trimmedPath}")")"
    if [[ "${firstCharacter}" = '/' ]]
    then
        echo "${trimmedPath}"
    else
        echo "$(pwd)/${trimmedPath}"
    fi
}

PortOpen() {
    local -r port="${1}"
    if [[ "$(EmptyString "${port}")" = 'true' ]]
    then
        echo 'false'
        return
    fi
    if command -v nc >/dev/null 2>&1
    then
        nc -z -w2 localhost "${port}" >/dev/null 2>&1
        if [[ "${?}" = '0' ]]
        then
            echo 'true'
        else
            echo 'false'
        fi
    else
        (echo > /dev/tcp/localhost/"${port}") >/dev/null 2>&1
        if [[ "${?}" = '0' ]]
        then
            echo 'true'
        else
            echo 'false'
        fi
    fi
}

error() {
    echo -e "\033[1;31m${1}\033[0m" >&2
}

fatal() {
    echo -e "\033[1;31m${1}\033[0m" >&2
    exit 1
}

# Fonction d'aide pour le systeme de tunnels
displayTunnelUsage() {
    local -r scriptName="$(basename "${BASH_SOURCE[0]}")"
    
    echo -e "\033[1;33m"
    echo    "SYNOPSIS TUNNELS SSH :"
    echo    "    ${scriptName} tunnel"
    echo    "        --help"
    echo    "        --configure"
    echo    "        --local-port       <LOCAL_PORT>"
    echo    "        --remote-port      <REMOTE_PORT>"
    echo    "        --local-to-remote"
    echo    "        --remote-to-local"
    echo    "        --remote-user      <REMOTE_USER>"
    echo    "        --remote-host      <REMOTE_HOST>"
    echo    "        --identity-file    <IDENTITY_FILE>"
    echo -e "\033[1;35m"
    echo    "DESCRIPTION :"
    echo    "    --help               Help page"
    echo    "    --configure          Config remote server to support forwarding (optional)"
    echo    "    --local-port         Local port number (require)"
    echo    "    --remote-port        Remote port number (require)"
    echo    "    --local-to-remote    Forward request from local machine to remote machine"
    echo    "    --remote-to-local    Forward request from remote machine to local machine"
    echo    "    --remote-user        Remote user (require)"
    echo    "    --remote-host        Remote host (require)"
    echo    "    --identity-file      Path to private key (*.ppk, *.pem) to access remote server (optional)"
    echo -e "\033[1;36m"
    echo    "EXAMPLES :"
    echo    "    ${scriptName} tunnel --help"
    echo    "    ${scriptName} tunnel --configure --remote-user 'root' --remote-host 'my-server.com'"
    echo    "    ${scriptName} tunnel --local-port 8080 --remote-port 9090 --local-to-remote --remote-user 'root' --remote-host 'my-server.com'"
    echo    "    ${scriptName} tunnel --local-port 8080 --remote-port 9090 --remote-to-local --remote-user 'root' --remote-host 'my-server.com'"
    echo -e "\033[0m"
}

# Fonction pour obtenir l'option de fichier d'identite
getIdentityFileOption() {
    local identityFile="${1}"
    
    if [[ "$(EmptyString "${identityFile}")" = 'false' && -f "${identityFile}" ]]
    then
        echo "-i \"${identityFile}\""
    else
        echo
    fi
}

# Fonction de configuration du serveur distant
configureRemoteServer() {
    local remoteUser="${1}"
    local remoteHost="${2}"
    local identityFile="${3}"
    
    local identityOption=''
    identityOption="$(getIdentityFileOption "${identityFile}")"
    
    local commands=''
    commands="
        # Permet de verifier les permissions root
        if [[ \$(id -u) -ne 0 ]]; then
            echo 'ERROR: Root permissions required for configuration'
            exit 1
        fi
        
        # Configurer AllowTcpForwarding
        if ! grep -q '^AllowTcpForwarding yes' /etc/ssh/sshd_config; then
            echo 'AllowTcpForwarding yes' >> /etc/ssh/sshd_config
            echo 'AllowTcpForwarding configured'
        fi
        
        # Configurer GatewayPorts
        if ! grep -q '^GatewayPorts yes' /etc/ssh/sshd_config; then
            echo 'GatewayPorts yes' >> /etc/ssh/sshd_config
            echo 'GatewayPorts configured'
        fi
        
        # Redémarrer SSH
        systemctl restart ssh || service ssh restart
        echo 'SSH service restarted'
    "
    
    echo "Configuration du serveur distant ${remoteHost}..."
    ssh ${identityOption} -n "${remoteUser}@${remoteHost}" "${commands}"
}

# Fonction de vérification des ports
verifyPort() {
    local port="${1}"
    local mustExist="${2}"
    local remoteUser="${3}"
    local remoteHost="${4}"
    local identityOption="${5}"
    
    if [[ "$(EmptyString "${remoteUser}")" = 'true' || "$(EmptyString "${remoteHost}")" = 'true' ]]
    then
        local isProcessRunning=''
        isProcessRunning="$(PortOpen "${port}")"
        local machineLocation='local'
    else
        local commands="
            if command -v nc >/dev/null 2>&1; then
                nc -z -w2 localhost \"${port}\" >/dev/null 2>&1
                if [[ \${?} = '0' ]]; then
                    echo 'true'
                else
                    echo 'false'
                fi
            else
                (echo > /dev/tcp/localhost/\"${port}\") >/dev/null 2>&1
                if [[ \${?} = '0' ]]; then
                    echo 'true'
                else
                    echo 'false'
                fi
            fi
        "
        
        local isProcessRunning=''
        isProcessRunning="$(ssh ${identityOption} -n "${remoteUser}@${remoteHost}" "${commands}")"
        local machineLocation="${remoteHost}"
    fi
    
    if [[ "${mustExist}" = 'true' && "${isProcessRunning}" = 'false' ]]
    then
        error "\nFATAL :"
        error "    - There is not a process listening to port ${port} on the '${machineLocation}' machine."
        fatal "    - Please make sure your process is listening to the port ${port} before trying to tunnel.\n"
    elif [[ "${mustExist}" = 'false' && "${isProcessRunning}" = 'true' ]]
    then
        error "\nFATAL :"
        error "    - There is a process listening to port ${port} on the '${machineLocation}' machine."
        fatal "    - Please make sure your process is not listening to the port ${port} before trying to tunnel.\n"
    fi
}

# Fonction principale de création de tunnel
createAdvancedTunnel() {
    local localPort="${1}"
    local remotePort="${2}"
    local tunnelDirection="${3}"
    local remoteUser="${4}"
    local remoteHost="${5}"
    local identityFile="${6}"
    
    # Obtenir l'option de fichier d'identite
    local identityOption=''
    identityOption="$(getIdentityFileOption "${identityFile}")"
    
    # Vérifier les ports
    if [[ "${tunnelDirection}" = 'local-to-remote' ]]
    then
        verifyPort "${localPort}" 'false'
        verifyPort "${remotePort}" 'true' "${remoteUser}" "${remoteHost}" "${identityOption}"
    elif [[ "${tunnelDirection}" = 'remote-to-local' ]]
    then
        verifyPort "${localPort}" 'true'
        verifyPort "${remotePort}" 'false' "${remoteUser}" "${remoteHost}" "${identityOption}"
    else
        fatal "\nFATAL : invalid tunnel direction '${tunnelDirection}'"
    fi
    
    # Vérifier la configuration distante
    local tcpForwardConfigFound=''
    tcpForwardConfigFound="$(ssh ${identityOption} -n "${remoteUser}@${remoteHost}" "grep -E -o '^AllowTcpForwarding yes' '/etc/ssh/sshd_config' 2>/dev/null || echo ''")"
    
    local gatewayConfigFound=''
    gatewayConfigFound="$(ssh ${identityOption} -n "${remoteUser}@${remoteHost}" "grep -E -o '^GatewayPorts yes' '/etc/ssh/sshd_config' 2>/dev/null || echo ''")"
    
    if [[ "$(EmptyString "${tcpForwardConfigFound}")" = 'true' || "$(EmptyString "${gatewayConfigFound}")" = 'true' ]]
    then
       error   "\nWARNING :"
       error   "    - Your remote host '${remoteHost}' is NOT yet configured for tunneling."
       echo -e "    \033[1;31m- Run '\033[1;33m--configure\033[1;31m' to set it up!\033[0m"
       error   "    - Will continue tunneling but it might NOT work for you!"
       sleep 5
    fi
    
    # Permet de demarrer le tunnel
    if [[ "${tunnelDirection}" = 'local-to-remote' ]]
    then
        doAdvancedTunnel 'localhost' "${localPort}" "${remoteHost}" "${remotePort}" '-L' "${remoteUser}" "${remoteHost}" "${identityOption}"
    else
        doAdvancedTunnel "${remoteHost}" "${remotePort}" 'localhost' "${localPort}" '-R' "${remoteUser}" "${remoteHost}" "${identityOption}"
    fi
}

# Fonction d'execution du tunnel
doAdvancedTunnel() {
    local sourceHost="${1}"
    local sourcePort="${2}"
    local destinationHost="${3}"
    local destinationPort="${4}"
    local directionOption="${5}"
    local remoteUser="${6}"
    local remoteHost="${7}"
    local identityOption="${8}"
    
    echo -e "\n\033[1;35m${sourceHost}:${sourcePort} \033[1;36mforwards to \033[1;32m${destinationHost}:${destinationPort}\033[0m\n"
    
    ssh -c '3des-cbc' \
        -C \
        -g \
        -N \
        -p 22 \
        -v \
        ${identityOption} \
        "${directionOption}" "${sourcePort}:localhost:${destinationPort}" \
        "${remoteUser}@${remoteHost}"
}

# Fonction principale pour gerer les tunnels
handleTunnelCommand() {
    shift # Supprime 'tunnel' des arguments
    
    local configure='false'
    local localPort=''
    local remotePort=''
    local tunnelDirection=''
    local remoteUser=''
    local remoteHost=''
    local identityFile=''
    
    # Configuration globale
    local sshdConfigFile='/etc/ssh/sshd_config'
    local tcpForwardConfigPattern='^\s*AllowTcpForwarding\s+yes\s*$'
    local gatewayConfigPattern='^\s*GatewayPorts\s+yes\s*$'
    
    # Traitement des arguments
    while [[ ${#} -gt 0 ]]
    do
        case "${1}" in
            --help)
                displayTunnelUsage
                return 0
                ;;
            --configure)
                shift
                configure='true'
                ;;
            --local-port)
                shift
                if [[ ${#} -gt 0 ]]
                then
                    localPort="$(trimString "${1}")"
                fi
                ;;
            --remote-port)
                shift
                if [[ ${#} -gt 0 ]]
                then
                    remotePort="$(trimString "${1}")"
                fi
                ;;
            --local-to-remote)
                shift
                tunnelDirection='local-to-remote'
                ;;
            --remote-to-local)
                shift
                tunnelDirection='remote-to-local'
                ;;
            --remote-user)
                shift
                if [[ ${#} -gt 0 ]]
                then
                    remoteUser="$(trimString "${1}")"
                fi
                ;;
            --remote-host)
                shift
                if [[ ${#} -gt 0 ]]
                then
                    remoteHost="$(trimString "${1}")"
                fi
                ;;
            --identity-file)
                shift
                if [[ ${#} -gt 0 ]]
                then
                    identityFile="$(formatPath "${1}")"
                fi
                ;;
            *)
                shift
                ;;
        esac
    done
    
    # Validation du fichier d'identite
    if [[ "$(EmptyString "${identityFile}")" = 'false' && ! -f "${identityFile}" ]]
    then
        fatal "\nFATAL : identity file '${identityFile}' not found!"
    fi
    
    # Execution
    if [[ "${configure}" = 'true' ]]
    then
        if [[ "$(EmptyString "${remoteUser}")" = 'true' || "$(EmptyString "${remoteHost}")" = 'true' ]]
        then
            error '\nERROR : remoteUser or remoteHost argument not found!'
            displayTunnelUsage
            return 1
        fi
        configureRemoteServer "${remoteUser}" "${remoteHost}" "${identityFile}"
    else
        if [[ "$(EmptyString "${localPort}")" = 'true' || "$(EmptyString "${remotePort}")" = 'true' ||
              "$(EmptyString "${tunnelDirection}")" = 'true' ||
              "$(EmptyString "${remoteUser}")" = 'true' || "$(EmptyString "${remoteHost}")" = 'true' ]]
        then
            error '\nERROR : localPort, remotePort, tunnelDirection, remoteUser, or remoteHost argument not found!'
            displayTunnelUsage
            return 1
        fi
        createAdvancedTunnel "${localPort}" "${remotePort}" "${tunnelDirection}" "${remoteUser}" "${remoteHost}" "${identityFile}"
    fi
}





