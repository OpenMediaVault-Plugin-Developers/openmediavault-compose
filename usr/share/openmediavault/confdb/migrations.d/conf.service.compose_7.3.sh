#!/bin/bash

set -e

. /usr/share/openmediavault/scripts/helper-functions

if ! omv_config_exists "/config/services/compose/configs"; then
  omv_config_add_node "/config/services/compose" "configs"
fi

exit 0

