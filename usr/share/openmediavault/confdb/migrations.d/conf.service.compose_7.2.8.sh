#!/bin/bash

set -e

. /usr/share/openmediavault/scripts/helper-functions

if ! omv_config_exists "/config/services/compose/showcmd"; then
  omv_config_add_key "/config/services/compose" "showcmd" "0"
fi

xpath="/config/services/compose/files/file"
count=$(omv_config_get_count "${xpath}");
index=1;
while [ ${index} -le ${count} ]; do
  pos="${xpath}[position()=${index}]"
  if ! omv_config_exists "${pos}/showenv"; then
    omv_config_add_key "${pos}" "showenv" "0"
  fi
  if ! omv_config_exists "${pos}/showoverride"; then
    omv_config_add_key "${pos}" "showoverride" "0"
  fi
  index=$(( index + 1 ))
done;

exit 0

