#!/bin/bash

set -e

. /usr/share/openmediavault/scripts/helper-functions

if ! omv_config_exists "/config/services/compose/configs"; then
  omv_config_add_node "/config/services/compose" "configs"
fi

xpath="/config/services/compose/jobs/job"
count=$(omv_config_get_count "${xpath}");
index=1;
while [ ${index} -le ${count} ]; do
  pos="${xpath}[position()=${index}]"
  if ! omv_config_exists "${pos}/excludes"; then
    omv_config_add_key "${pos}" "excludes" ""
  fi
  index=$(( index + 1 ))
done;

exit 0

