#!/bin/bash

set -e

. /usr/share/openmediavault/scripts/helper-functions

if ! omv_config_exists "/config/services/compose/execenable"; then
  omv_config_add_key "/config/services/compose" "execenable" 0 
fi

if ! omv_config_exists "/config/services/compose/host"; then
  omv_config_add_key "/config/services/compose" "host" "0.0.0.0"
fi

if ! omv_config_exists "/config/services/compose/port"; then
  omv_config_add_key "/config/services/compose" "port" "5000"
fi

if ! omv_config_exists "/config/services/compose/debug"; then
  omv_config_add_key "/config/services/compose" "debug" "0"
fi

omv_module_set_dirty compose

exit 0

