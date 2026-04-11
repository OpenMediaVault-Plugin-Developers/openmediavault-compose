#!/bin/bash

set -e

. /usr/share/openmediavault/scripts/helper-functions

echo "Updating database ..."

xpath="/config/services/compose/jobs/job"

xmlstarlet sel -t -m "${xpath}" -v "uuid" -n ${OMV_CONFIG_FILE} |
  xmlstarlet unesc |
  while read uuid; do
    if ! omv_config_exists "${xpath}[uuid='${uuid}']/excludefilter"; then
      omv_config_add_key "${xpath}[uuid='${uuid}']" "excludefilter" ""
    fi
  done

omv_module_set_dirty compose

exit 0
