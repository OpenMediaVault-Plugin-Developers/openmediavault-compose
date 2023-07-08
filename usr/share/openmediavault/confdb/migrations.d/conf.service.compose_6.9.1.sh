#!/bin/sh

set -e

. /usr/share/openmediavault/scripts/helper-functions

if ! omv_config_exists "/config/services/compose/composeowner"; then
  omv_config_add_key "/config/services/compose" "composeowner" "root"
  omv_module_set_dirty compose
fi
if ! omv_config_exists "/config/services/compose/composegroup"; then
  omv_config_add_key "/config/services/compose" "composegroup" "root"
fi
if ! omv_config_exists "/config/services/compose/mode"; then
  omv_config_add_key "/config/services/compose" "mode" "700"
fi
if ! omv_config_exists "/config/services/compose/fileperms"; then
  omv_config_add_key "/config/services/compose" "fileperms" "600"
fi

exit 0
