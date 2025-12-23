#!/bin/bash

set -e

. /usr/share/openmediavault/scripts/helper-functions

if ! omv_config_exists "/config/services/compose/podman"; then
  omv_config_add_key "/config/services/compose" "podman" "0"
fi

exit 0
