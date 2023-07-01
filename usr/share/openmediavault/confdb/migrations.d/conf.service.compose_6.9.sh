#!/bin/sh

set -e

. /usr/share/openmediavault/scripts/helper-functions

if ! omv_config_exists "/config/services/compose/backupsharedfolderref"; then
  omv_config_add_key "/config/services/compose" "backupsharedfolderref" ""
fi
if ! omv_config_exists "/config/services/compose/backupmaxsize"; then
  omv_config_add_key "/config/services/compose" "backupmaxsize" "1"
fi
if ! omv_config_exists "/config/services/compose/jobs"; then
  omv_config_add_node "/config/services/compose" "jobs"
fi

exit 0

