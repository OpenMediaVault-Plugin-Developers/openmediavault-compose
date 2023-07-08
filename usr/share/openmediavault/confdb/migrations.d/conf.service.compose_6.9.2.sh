#!/bin/sh

set -e

. /usr/share/openmediavault/scripts/helper-functions

if ! omv_config_exists "/config/services/compose/datasharedfolderref"; then
  omv_config_add_key "/config/services/compose" "datasharedfolderref" ""
fi

exit 0

