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
  if ! omv_config_exists "${pos}/env"; then
    omv_config_add_key "${pos}" "env" ""
    status=1
  fi
  index=$(( index + 1 ))
done;

if [ ${status} -eq 1 ]; then
  # update compose files and put in sub-directories
  echo "Regenerating compose files and moving to sub-directories ..."
  omv-salt deploy run compose

  # remove old compose files in root directory
  sfref=$(omv_config_get "/config/services/compose/sharedfolderref")
  sfpath=$(omv_get_sharedfolder_path "${sfref}")
  echo "Removing old compose files from ${sfpath} ..."
  if [ -d "${sfpath}" ] && [ ! "${sfpath}" = "/" ]; then
    find "${sfpath}" -maxdepth 1 -type f -name "*.yml" -print -delete
  fi
fi

exit 0

