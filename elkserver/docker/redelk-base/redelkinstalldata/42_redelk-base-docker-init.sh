#!/bin/bash
#
# Part of RedELK
# Script to install specifics on init of redelk-base docker container
#
# Author: Outflank B.V. / Marc Smeets
#

LOGFILE="/var/log/redelk/redelk-docker-init2.log"

upcheck_elasticsearch() {
    COUNTER=0
    RECHECK=true
    while [ "$RECHECK" = true ]; do
        touch /tmp/esupcheck.txt
        curl -s -S -XGET 'http://redelk-elasticsearch:9200/' -o /tmp/esupcheck.txt >> $LOGFILE 2>&1
        if [ -n "$(grep 'name' /tmp/esupcheck.txt)" ]; then
            RECHECK=false
        else
            echo "[!] Elasticsearch not up, sleeping another few seconds." | tee -a $LOGFILE
            sleep 10
            COUNTER=$((COUNTER+1))
            if [ $COUNTER -eq "30" ]; then
                echo "[!] Elasticsearch still not up, waited for way too long. Continuing and hoping for the best."  | tee -a $LOGFILE
                RECHECK=false
            fi
        fi
        rm /tmp/esupcheck.txt
    done
}

upcheck_kibana() {
    COUNTER=0
    RECHECK=true
    while [ "$RECHECK" = true ]; do
        touch /tmp/kibanaupcheck.txt
        curl -s -S -XGET 'http://redelk-kibana:5601/status' -I -o /tmp/kibanaupcheck.txt >> $LOGFILE 2>&1
        if [ -n "$(grep '200 OK' /tmp/kibanaupcheck.txt)" ]; then
            RECHECK=false
        else
            echo "[!] Kibana not up yet, sleeping another few seconds." | tee -a $LOGFILE
            sleep 10
            COUNTER=$((COUNTER+1))
            if [ $COUNTER -eq "30" ]; then
                echo "[!] Kibana still not up, waited for way too long. Continuing and hoping for the best."  | tee -a $LOGFILE
                RECHECK=false
            fi
        fi
        rm /tmp/kibanaupcheck.txt
    done
}

# Start with echo to logfile
echo "[*]    `date +'%b %e %R'` Starting installer" | tee -a $LOGFILE

# Check if redelk user already exists, if not create
grep redelk /etc/passwd >> /dev/null
EXISTS=$?
if [ ! $(grep redelk /etc/passwd ) >> /dev/null ]; then
    echo "[*] Adding redelk user" | tee -a $LOGFILE
    useradd -m -p $(openssl passwd -1 `head /dev/urandom | tr -dc A-Za-z0-9 | head -c20`) redelk && usermod -a -G www-data redelk >> $LOGFILE 2>&1
else
    echo "[*] User redelk already exists, nothing to do" | tee -a $LOGFILE
fi
echo "" >> $LOGFILE

# Set relevant permissions for redelk user
echo "[*] Setting dir persmisisons for redelk user" | tee -a $LOGFILE
chown -Rv redelk /var/log/redelk/ && chown -Rv www-data:redelk /var/www/html/c2logs && chown -Rv redelk /etc/redelk && chmod 775 /var/www/html/c2logs >> $LOGFILE 2>&1
ERROR=$?
if [ $ERROR -ne 0 ]; then
    echo "[X] Could not set dir permissions for redelk user (Error Code: $ERROR)."
fi
echo "" >> $LOGFILE

# set ssh keys permissions
echo "[*] Setting ssh key persmisisons for redelk user" | tee -a $LOGFILE
chown -R redelk:redelk /home/redelk/.ssh && chmod 700 /home/redelk/.ssh && chmod 600 /home/redelk/.ssh/id* >> $LOGFILE 2>&1
ERROR=$?
if [ $ERROR -ne 0 ]; then
    echo "[X] Could not set ssh keypermissions for redelk user (Error Code: $ERROR)."
fi
echo "" >> $LOGFILE

# First check if ES and Kibana are up before doing any followup step
upcheck_elasticsearch
upcheck_kibana

# Start with specifcs for elasticsearch
echo "[*] Preparing the SIEM signals index" | tee -a $LOGFILE
upcheck_elasticsearch
curl -s -S -X PUT "http://redelk-elasticsearch:9200/.siem-signals-default?pretty" >> $LOGFILE 2>&1
ERROR=$?
if [ $ERROR -ne 0 ]; then
    echo "[X] Could not prepare the SIEM signals index (Error Code: $ERROR)."
fi
echo "" >> $LOGFILE

echo "[*] Installing Elasticsearch ILM policy" | tee -a $LOGFILE
upcheck_elasticsearch
curl -s -S -X PUT "http://redelk-elasticsearch:9200/_ilm/policy/redelk" -H "Content-Type: application/json" -d @./root/redelkinstalldata/templates/redelk_elasticsearch_ilm.json >> $LOGFILE 2>&1
ERROR=$?
if [ $ERROR -ne 0 ]; then
    echo "[X] Could not install Elasticsearch ILM policy (Error Code: $ERROR)."
fi
echo "" >> $LOGFILE

echo "[*] Installing Elasticsearch index templates" | tee -a $LOGFILE
upcheck_elasticsearch
for i in implantsdb rtops redirtraffic; do curl -s -S -X POST "http://redelk-elasticsearch:9200/_template/$i" -H "Content-Type: application/json" -d @./root/redelkinstalldata/templates/redelk_elasticsearch_template_$i.json; done >> $LOGFILE 2>&1
ERROR=$?
if [ $ERROR -ne 0 ]; then
    echo "[X] Could not install Elasticsearch index templates (Error Code: $ERROR)."
fi
echo "" >> $LOGFILE

# Now Kibana specifics
echo "[*] Installing Kibana index patterns" | tee -a $LOGFILE
upcheck_kibana
for i in ./root/redelkinstalldata/templates/redelk_kibana_index-pattern*.ndjson; do
    curl -s -S -X POST "http://redelk-kibana:5601/api/saved_objects/_import?overwrite=true" -H 'kbn-xsrf: true' -F file=@$i
    sleep 1
done >> $LOGFILE 2>&1
ERROR=$?
if [ $ERROR -ne 0 ]; then
    echo "[X] Could not install Kibana index patterns (Error Code: $ERROR)."
fi
echo "" >> $LOGFILE

echo "[*] Installing Kibana searches" | tee -a $LOGFILE
upcheck_kibana
curl -s -S -X POST "http://redelk-kibana:5601/api/saved_objects/_import?overwrite=true" -H 'kbn-xsrf: true' -F file=@./root/redelkinstalldata/templates/redelk_kibana_search.ndjson >> $LOGFILE 2>&1
ERROR=$?
if [ $ERROR -ne 0 ]; then
    echo "[X] Could not install Kibana searches (Error Code: $ERROR)."
fi
echo "" >> $LOGFILE

echo "[*] Installing Kibana visualizations" | tee -a $LOGFILE
upcheck_kibana
curl -s -S -X POST "http://redelk-kibana:5601/api/saved_objects/_import?overwrite=true" -H 'kbn-xsrf: true' -F file=@./root/redelkinstalldata/templates/redelk_kibana_visualization.ndjson >> $LOGFILE 2>&1
ERROR=$?
if [ $ERROR -ne 0 ]; then
    echo "[X] Could not install Kibana visualizations (Error Code: $ERROR)."
fi
echo "" >> $LOGFILE

echo "[*] Installing Kibana dashboards" | tee -a $LOGFILE
upcheck_kibana
curl -s -S -X POST "http://redelk-kibana:5601/api/saved_objects/_import?overwrite=true" -H 'kbn-xsrf: true' -F file=@./root/redelkinstalldata/templates/redelk_kibana_dashboard.ndjson >> $LOGFILE 2>&1
ERROR=$?
if [ $ERROR -ne 0 ]; then
    echo "[X] Could not install Kibana dashboards (Error Code: $ERROR)."
fi
echo "" >> $LOGFILE

echo "[*] Installing Kibana advanced settings" | tee -a $LOGFILE
upcheck_kibana
curl -s -S -X POST "http://redelk-kibana:5601/api/kibana/settings" -H 'kbn-xsrf: true' -H 'Content-Type: application/json' --data @./root/redelkinstalldata/templates/redelk_kibana_settings.json >> $LOGFILE 2>&1
ERROR=$?
if [ $ERROR -ne 0 ]; then
   echo "[X] Could not install Kibana advanced settings (Error Code: $ERROR)."
fi
echo "" >> $LOGFILE

echo "[*] Installing Kibana SIEM detection rules (for MITRE ATT&CK mapping)" | tee -a $LOGFILE
upcheck_kibana
curl -s -S -X POST "http://redelk-kibana:5601/api/detection_engine/rules/_import?overwrite=true" -H 'kbn-xsrf: true' -F file=@./root/redelkinstalldata/templates/redelk_siem_detection_rules.ndjson >> $LOGFILE 2>&1
ERROR=$?
if [ $ERROR -ne 0 ]; then
    echo "[X] Could not install Kibana SIEM detection rules (Error Code: $ERROR)."
fi
echo "" >> $LOGFILE

echo "[*] Inserting the superawesomesauce RedELK logo into Kibana" | tee -a $LOGFILE
upcheck_kibana
curl -s -S 'http://redelk-kibana:5601/api/spaces/space/default?overwrite=true' -H 'kbn-xsrf: true' -X PUT -H 'Content-Type: application/json' -d @./root/redelkinstalldata/kibana/redelklogo.json >> $LOGFILE 2>&1
ERROR=$?
if [ $ERROR -ne 0 ]; then
    echo "[X] Could not adjust Kibana logo (Error Code: $ERROR)."
fi
echo "" >> $LOGFILE

# End with echo to logfile and some white lines
echo "[*]    `date +'%b %e %R'` Installer finished" | tee -a $LOGFILE
echo "" >> $LOGFILE
echo "" >> $LOGFILE
echo "" >> $LOGFILE
echo "" >> $LOGFILE
echo "" >> $LOGFILE