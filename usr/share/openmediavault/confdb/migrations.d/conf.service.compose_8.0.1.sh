#!/bin/bash

set -e

. /usr/share/openmediavault/scripts/helper-functions

if ! omv_config_exists "/config/services/compose/runconfig"; then
  omv_config_add_key "/config/services/compose" "runconfig" "0"
fi

exit 0

