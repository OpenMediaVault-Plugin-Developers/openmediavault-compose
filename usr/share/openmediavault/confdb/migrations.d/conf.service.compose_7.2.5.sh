#!/bin/sh

set -e

. /usr/share/openmediavault/scripts/helper-functions

status=0

echo "Updating database ..."
xpath="/config/services/compose/files/file"
count=$(omv_config_get_count "${xpath}");
index=1;
while [ ${index} -le ${count} ]; do
  pos="${xpath}[position()=${index}]"
  if ! omv_config_exists "${pos}/override"; then
    omv_config_add_key "${pos}" "override" ""
  fi
  index=$(( index + 1 ))
done;

omv_module_set_dirty compose

exit 0

