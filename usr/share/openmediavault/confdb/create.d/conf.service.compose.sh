#!/bin/sh
#
# @license   http://www.gnu.org/licenses/gpl.html GPL Version 3
# @author    OpenMediaVault Plugin Developers <plugins@omv-extras.org>
# @copyright Copyright (c) 2022-2025 openmediavault plugin developers
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

. /etc/default/openmediavault
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
  omv_config_add_key "/config/services/compose" "composeowner" "root"
  omv_config_add_key "/config/services/compose" "composegroup" "root"
  omv_config_add_key "/config/services/compose" "mode" "700"
  omv_config_add_key "/config/services/compose" "fileperms" "600"
  omv_config_add_key "/config/services/compose" "datasharedfolderref" ""
  omv_config_add_key "/config/services/compose" "backupsharedfolderref" ""
  omv_config_add_key "/config/services/compose" "backupmaxsize" "1"
  omv_config_add_key "/config/services/compose" "dockerStorage" "${dockerPath}"
  omv_config_add_key "/config/services/compose" "urlHostname" ""
  omv_config_add_key "/config/services/compose" "cachetimefiles" "60"
  omv_config_add_key "/config/services/compose" "cachetimeservices" "60"
  omv_config_add_key "/config/services/compose" "cachetimestats" "60"
  omv_config_add_key "/config/services/compose" "cachetimeimages" "60"
  omv_config_add_key "/config/services/compose" "cachetimenetworks" "60"
  omv_config_add_key "/config/services/compose" "cachetimevolumes" "60"
  omv_config_add_key "/config/services/compose" "cachetimecontainers" "60"
  omv_config_add_key "/config/services/compose" "showcmd" "0"
  omv_config_add_key "/config/services/compose" "execenable" 0
  omv_config_add_key "/config/services/compose" "host" "0.0.0.0"
  omv_config_add_key "/config/services/compose" "port" "5000"
  omv_config_add_key "/config/services/compose" "debug" "0"
  omv_config_add_node "/config/services/compose" "files"
  omv_config_add_node "/config/services/compose" "configs"
  omv_config_add_node "/config/services/compose" "dockerfiles"
  omv_config_add_node "/config/services/compose" "jobs"
  omv_config_add_node "/config/services/compose" "globalenv"
  omv_config_add_key "/config/services/compose/globalenv" "enabled" "1"
  omv_config_add_key "/config/services/compose/globalenv" "globalenv" ""
fi

# download yq
version="v4.45.2"
bindir="/usr/local/bin"
yq="${bindir}/yq"
arch="$(dpkg --print-architecture)"
case "${arch}" in
  armhf) arch="arm" ;;
  i386) arch="386" ;;
esac
repo_url=${OMV_EXTRAS_YQ_URL:-"https://github.com/mikefarah/yq/releases/download"}
if [ ! -d "${bindir}" ]; then
  mkdir -p ${bindir}
fi
if [ ! -f "${yq}" ]; then
  echo "Downloading yq ..."
  wget -O ${yq} "${repo_url}/${version}/yq_linux_${arch}"
else
  echo "Checking yq version ..."
  chmod 755 ${yq}
  yqvers="$(${yq} -V | awk '{ print $4 }')"
  if [ ! "${version}" = "${yqvers}" ]; then
    wget -O ${yq} "${repo_url}/${version}/yq_linux_${arch}"
  else
    echo "Correct version of yq installed - '${version}'"
  fi
fi
chmod 755 ${yq}

# download regctl
arch="$(dpkg --print-architecture)"
if [ "${arch}" = "amd64" ] || [ "${arch}" = "arm64" ]; then
  version="v0.8.3"
  bindir="/usr/local/bin"
  regctl="${bindir}/regctl"
  repo_url=${OMV_EXTRAS_REGCTL_URL:-"https://github.com/regclient/regclient/releases/download"}
  if [ ! -f "${regctl}" ]; then
    echo "Downloading regctl ..."
    wget -O ${regctl} "${repo_url}/${version}/regctl-linux-${arch}"
  else
    echo "Checking regctl version ..."
    chmod 755 ${regctl}
    regctlvers="$(${regctl} version | awk '$1 == "VCSTag:" { print $2 }')"
    if [ ! "${version}" = "${regctlvers}" ]; then
      wget -O ${regctl} "${repo_url}/${version}/regctl-linux-${arch}"
    else
      echo "Correct version of regctl installed - '${version}'"
    fi
  fi
  chmod 755 ${regctl}
fi

# make sure log files exist to eliminate log viewer error
for log in backup restore update; do
  file="/var/log/omv-compose-${log}.log"
  if [ ! -f "${file}" ]; then
    touch ${file}
  fi
done

# download icons
echo "Downloading example file icons ..."
omv-compose-download-icons

exit 0
