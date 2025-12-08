#!/bin/bash

set -e

. /usr/share/openmediavault/scripts/helper-functions

if ! omv_config_exists "/config/services/compose/dockersharedfolderref"; then
  omv_config_add_key "/config/services/compose" "dockersharedfolderref" ""
fi

exit 0

