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
  if ! omv_config_exists "${pos}/backup"; then
    omv_config_add_key "${pos}" "backup" "1"
    status=1
  fi
  if ! omv_config_exists "${pos}/update"; then
    omv_config_add_key "${pos}" "update" "0"
    status=1
  fi
  index=$(( index + 1 ))
done;

if [ ${status} -eq 1 ]; then
  # update jobs to add backup and update fields
  echo "Regenerating jobs to add backup and update fields ..."
  omv-salt deploy run compose
fi

exit 0

