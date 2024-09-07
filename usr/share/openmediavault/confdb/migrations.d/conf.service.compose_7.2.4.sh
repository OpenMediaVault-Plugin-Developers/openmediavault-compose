#!/bin/bash

set -e

. /usr/share/openmediavault/scripts/helper-functions

if ! omv_config_exists "/config/services/compose/urlHostname"; then
  omv_config_add_key "/config/services/compose" "urlHostname" ""
fi

exit 0

