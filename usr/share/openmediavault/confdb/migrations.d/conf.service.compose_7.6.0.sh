#!/bin/bash

set -e

. /usr/share/openmediavault/scripts/helper-functions

echo "Updating database ..."

change=0

for i in execenable host port debug hostshell; do
  if omv_config_exists "/config/services/compose/${i}"; then
    omv_config_delete "/config/services/compose/${i}"
    change=1
  fi
done

if [ ${change} -eq 1 ]; then
  # stop and remove service
  term="omv_compose_term.service"
  unit="/etc/systemd/system/${term}"
  if [ -f "${unit}" ]; then
    systemctl stop "${term}" || :
    rm -fv "${unit}"
    systemctl daemon-reload
  fi
  rm -rfv /opt/omv_compose_term
  rm -fv /etc/omv_compose_term.conf
  omv_module_set_dirty compose
fi

exit 0
