#!/bin/bash

set -e

. /usr/share/openmediavault/scripts/helper-functions

echo "Updating database ..."

if ! omv_config_exists "/config/services/compose/createsymlinks"; then
  omv_config_add_key "/config/services/compose" "createsymlinks" "1"
fi

exit 0
