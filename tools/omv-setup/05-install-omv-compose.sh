#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
need_root

if dpkg -l openmediavault-compose 2>/dev/null | grep -q '^ii'; then
  log "openmediavault-compose already installed"
  exit 0
fi

log "Installing openmediavault-compose..."
apt-get update -qq
apt-get install -y openmediavault-compose
log "openmediavault-compose installed"
