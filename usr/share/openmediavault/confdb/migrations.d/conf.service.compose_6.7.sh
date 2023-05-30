#!/bin/sh

set -e

. /usr/share/openmediavault/scripts/helper-functions

if ! omv_config_exists "/config/services/compose/dockerStorage"; then
  dockerPath="/var/lib/docker"
  if [ -f "/usr/bin/docker" ]; then
    dockerRoot="$(docker info | grep "Docker Root Dir:" | awk '{ print $4 }')"
    if [ -d "${dockerRoot}" ]; then
      dockerPath="${dockerRoot}"
    fi
  fi 
  omv_config_add_key "/config/services/compose" "dockerStorage" "${dockerPath}"
fi

exit 0

