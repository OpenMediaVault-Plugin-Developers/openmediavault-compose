#!/bin/bash

set -e

. /usr/share/openmediavault/scripts/helper-functions

if ! omv_config_exists "/config/services/compose/runconfig"; then
  omv_config_add_key "/config/services/compose" "runconfig" "0"
fi

if ! omv_config_exists "/config/services/compose/logmaxsize"; then
  omv_config_add_key "/config/services/compose" "logmaxsize" "50"
fi

if ! omv_config_exists "/config/services/compose/liverestore"; then
  omv_config_add_key "/config/services/compose" "liverestore" "0"
fi

omv_module_set_dirty compose

exit 0

