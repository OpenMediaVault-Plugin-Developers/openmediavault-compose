#!/bin/sh

set -e

. /usr/share/openmediavault/scripts/helper-functions

echo "Updating database ..."
xpath="/config/services/compose/jobs/job"
count=$(omv_config_get_count "${xpath}");
index=1;
while [ ${index} -le ${count} ]; do
  pos="${xpath}[position()=${index}]"
  if ! omv_config_exists "${pos}/prebackup"; then
    omv_config_add_key "${pos}" "prebackup" ""
  fi
  if ! omv_config_exists "${pos}/postbackup"; then
    omv_config_add_key "${pos}" "postbackup" ""
  fi
  index=$(( index + 1 ))
done;

omv_module_set_dirty compose

exit 0

