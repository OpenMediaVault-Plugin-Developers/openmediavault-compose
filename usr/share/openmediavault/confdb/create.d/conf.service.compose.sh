#!/bin/sh
#
# @license   http://www.gnu.org/licenses/gpl.html GPL Version 3
# @author    OpenMediaVault Plugin Developers <plugins@omv-extras.org>
# @copyright Copyright (c) 2022-2023 OpenMediaVault Plugin Developers
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

set -e

. /usr/share/openmediavault/scripts/helper-functions

if ! omv_config_exists "/config/services/compose"; then
  dockerPath="/var/lib/docker"
  if [ -f "/usr/bin/docker" ]; then
    dockerRoot="$(docker info | grep "Docker Root Dir:" | awk '{ print $4 }')"
    if [ -d "${dockerRoot}" ]; then
      dockerPath="${dockerRoot}"
    fi
  fi
  daemonJson="/etc/docker/daemon.json"
  if [ -f "${daemonJson}" ]; then
    if grep -qi nvidia ${daemonJson}; then
      dockerPath=""
    fi
  fi
  omv_config_add_node "/config/services" "compose"
  omv_config_add_key "/config/services/compose" "sharedfolderref" ""
  omv_config_add_key "/config/services/compose" "backupsharedfolderref" ""
  omv_config_add_key "/config/services/compose" "backupmaxsize" "1"
  omv_config_add_key "/config/services/compose" "dockerStorage" "${dockerPath}"
  omv_config_add_node "/config/services/compose" "files"
  omv_config_add_node "/config/services/compose" "dockerfiles"
fi

exit 0
