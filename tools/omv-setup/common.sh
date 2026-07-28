#!/usr/bin/env bash
# Sourced by all scripts. Not executable on its own.
set -euo pipefail

# -- Configurable via environment --
SVC_USER="${OMV_SVC_USER:-svc_docker}"
SVC_GROUP="${OMV_SVC_GROUP:-grp_docker}"
DOCKER_GROUP="docker"
DATA_ROOT="${OMV_DATA_ROOT:-/mnt/data}"
DATA_DIRS=(appdata compose backup share)
COMPOSE_DIR_MODE="750"
COMPOSE_FILE_MODE="640"

# The human who SSH'd in (works through sudo)
CALLING_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"

# OMV's sentinel UUID for "create new object"
OMV_NEW_UUID="fa4b1c66-ef79-11e5-87a0-0002b3a176b4"

# -- Helpers --

log() { echo "[omv-setup] $*"; }

need_root() {
  [[ $EUID -eq 0 ]] || { log "ERROR: must run as root (use sudo)"; exit 1; }
}

omv_rpc() {
  local service="$1" method="$2" params="${3:-{}}"
  omv-rpc -u admin "$service" "$method" "$params"
}
