#!/bin/bash

set -e

. /usr/share/openmediavault/scripts/helper-functions

echo "Updating database ..."

if ! omv_config_exists "/config/services/compose/borgencryption"; then
  omv_config_add_key "/config/services/compose" "borgencryption" "none"
fi
if ! omv_config_exists "/config/services/compose/borgpassphrase"; then
  omv_config_add_key "/config/services/compose" "borgpassphrase" ""
fi

exit 0
