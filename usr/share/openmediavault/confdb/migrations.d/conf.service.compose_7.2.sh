#!/bin/bash

set -e

. /usr/share/openmediavault/scripts/helper-functions

xpath="/config/services/compose"
keys=("files" "services" "stats" "images" "networks" "volumes" "containers")

for key in "${keys[@]}"; do
  if ! omv_config_exists "${xpath}/cachetime${key}"; then
    omv_config_add_key "${xpath}" "cachetime${key}" "60"
  fi
done

exit 0

