#!/bin/sh

set -e

. /usr/share/openmediavault/scripts/helper-functions

status=0

echo "Updating database ..."
xpath="/config/services/compose/jobs/job"
count=$(omv_config_get_count "${xpath}");
index=1;
while [ ${index} -le ${count} ]; do
  pos="${xpath}[position()=${index}]"
  if ! omv_config_exists "${pos}/filestart"; then
    omv_config_add_key "${pos}" "filestart" "0"
    status=1
  fi
  if ! omv_config_exists "${pos}/filestop"; then
    omv_config_add_key "${pos}" "filestop" "0"
    status=1
  fi
  index=$(( index + 1 ))
done;

if [ ${status} -eq 1 ]; then
  omv_module_set_dirty compose
fi

exit 0

