
#!/bin/bash
# Script de surveillance et de relance automatique du tunnel IPSec

LOG_FILE="/var/log/watchdog.log"
DATE=$(date "+%Y-%m-%d %H:%M:%S")

# Vérifie si le tunnel IPSec est établi
STATUS=$(ipsec status | grep ESTABLISHED)

if [ -z "$STATUS" ]; then
    echo "$DATE : Tunnel IPSec inactif, redémarrage." >> $LOG_FILE
    ipsec restart
    sleep 5
    STATUS_AFTER=$(ipsec status | grep ESTABLISHED)
    if [ -n "$STATUS_AFTER" ]; then
        echo "$DATE : Tunnel IPSec rétabli avec succès." >> $LOG_FILE
    else
        echo "$DATE : Échec du redémarrage du tunnel IPSec." >> $LOG_FILE
    fi
else
    echo "$DATE : Tunnel IPSec actif." >> $LOG_FILE
fi


echo "chmod +x /usr/local/bin/ipsec_watchdog.sh et nano /etc/crontab"

echo "*/5 * * * * root /usr/local/bin/watchdog.sh" >> /etc/crontab
echo "Ajouter la ligne ci-dessus au crontab pour exécuter le script toutes les 5 minutes."
echo "service cron restart pour appliquer les changements"
