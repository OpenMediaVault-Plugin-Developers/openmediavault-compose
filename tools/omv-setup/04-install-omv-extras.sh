#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
need_root

if dpkg -l openmediavault-omvextrasorg 2>/dev/null | grep -q '^ii'; then
  log "omv-extras already installed"
  exit 0
fi

log "Installing omv-extras..."
wget -qO /tmp/omv-extras-install.sh \
  https://github.com/OpenMediaVault-Plugin-Developers/installScript/raw/master/install
bash /tmp/omv-extras-install.sh
rm -f /tmp/omv-extras-install.sh
log "omv-extras installed"
