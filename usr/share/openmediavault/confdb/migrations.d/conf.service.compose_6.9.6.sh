#!/bin/sh

set -e

. /usr/share/openmediavault/scripts/helper-functions

if ! omv_config_exists "/config/services/compose/globalenv"; then
  omv_config_add_node "/config/services/compose" "globalenv"
  omv_config_add_key "/config/services/compose/globalenv" "enabled" "1"
  omv_config_add_key "/config/services/compose/globalenv" "globalenv" ""
fi

exit 0

