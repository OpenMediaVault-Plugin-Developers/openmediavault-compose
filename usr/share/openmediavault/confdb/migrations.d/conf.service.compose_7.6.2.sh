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

exit 0
