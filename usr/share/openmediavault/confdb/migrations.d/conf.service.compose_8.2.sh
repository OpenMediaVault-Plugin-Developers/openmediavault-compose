#!/bin/bash

set -e

. /usr/share/openmediavault/scripts/helper-functions

status=0

echo "Updating database ..."

if ! omv_config_exists "/config/services/compose/containerdImageStore"; then
  omv_config_add_key "/config/services/compose" "containerdImageStore" "0"
  status=1
fi

if ! omv_config_exists "/config/services/compose/disableIpv6"; then
  omv_config_add_key "/config/services/compose" "disableIpv6" "0"
  status=1
fi

if [ ${status} -eq 1 ]; then
  omv_module_set_dirty compose
fi

exit 0
