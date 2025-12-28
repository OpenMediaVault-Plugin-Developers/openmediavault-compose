#!/bin/bash

set -e

. /usr/share/openmediavault/scripts/helper-functions

status=0

echo "Updating database ..."

if ! omv_config_exists "/config/services/compose/podman"; then
  omv_config_add_key "/config/services/compose" "podman" "0"
  status=1
fi

if ! omv_config_exists "/config/services/compose/podmanStorage"; then
  omv_config_add_key "/config/services/compose" "podmanStorage" "/var/lib/containers/storage"
  status=1
fi

if ! omv_config_exists "/config/services/compose/podmansharedfolderref"; then
  omv_config_add_key "/config/services/compose" "podmansharedfolderref" ""
  status=1
fi

xpath="/config/services/compose/jobs/job"
count=$(omv_config_get_count "${xpath}");
index=1;
while [ ${index} -le ${count} ]; do
  pos="${xpath}[position()=${index}]"
  if ! omv_config_exists "${pos}/filebuild"; then
    omv_config_add_key "${pos}" "filebuild" "0"
    status=1
  fi
  if ! omv_config_exists "${pos}/filepull"; then
    omv_config_add_key "${pos}" "filepull" "0"
    status=1
  fi
  index=$(( index + 1 ))
done;

if [ ${status} -eq 1 ]; then
  omv_module_set_dirty compose
fi

exit 0
