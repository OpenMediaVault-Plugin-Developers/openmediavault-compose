#!/bin/sh

set -e

. /usr/share/openmediavault/scripts/helper-functions

if ! omv_config_exists "/config/services/compose/all"; then
  omv_config_add_key "/config/services/compose" "all" "0"
fi

exit 0

