#!/bin/bash

set -e

. /usr/share/openmediavault/scripts/helper-functions

echo "Updating database ..."

if ! omv_config_exists "/config/services/compose/hostshell"; then
  omv_config_add_key "/config/services/compose" "hostshell" "0"
  omv_module_set_dirty compose
fi

exit 0
