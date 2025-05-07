#!/bin/bash

set -e

. /usr/share/openmediavault/scripts/helper-functions

status=0

echo "Updating database ..."

if ! omv_config_exists "/config/services/compose/execenable"; then
  omv_config_add_key "/config/services/compose" "execenable" 0 
  status=1
fi

if ! omv_config_exists "/config/services/compose/host"; then
  omv_config_add_key "/config/services/compose" "host" "0.0.0.0"
  status=1
fi

if ! omv_config_exists "/config/services/compose/port"; then
  omv_config_add_key "/config/services/compose" "port" "5000"
  status=1
fi

if ! omv_config_exists "/config/services/compose/debug"; then
  omv_config_add_key "/config/services/compose" "debug" "0"
  status=1
fi

xpath="/config/services/compose/jobs/job"
count=$(omv_config_get_count "${xpath}");
index=1;
while [ ${index} -le ${count} ]; do
  pos="${xpath}[position()=${index}]"
  if ! omv_config_exists "${pos}/verbose"; then
    omv_config_add_key "${pos}" "verbose" "1"
    status=1
  fi
  index=$(( index + 1 ))
done;

if [ ${status} -eq 1 ]; then
  omv_module_set_dirty compose
fi

exit 0
