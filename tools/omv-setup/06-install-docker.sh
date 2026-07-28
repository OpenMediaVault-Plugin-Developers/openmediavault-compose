#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
need_root

if dpkg -l docker-ce 2>/dev/null | grep -q '^ii'; then
  log "Docker CE already installed"
  exit 0
fi

log "Installing Docker via OMV salt state..."

# Enable docker apt repo through OMV's mechanism
. /etc/default/openmediavault 2>/dev/null || true
omv_rpc "OmvExtras" "setDocker" '{"docker":true}' 2>/dev/null || \
  omv_rpc "OmvExtras" "set" '{"docker":true}' 2>/dev/null || true

# Refresh apt sources
omv-aptclean repos 2>/dev/null || true
apt-get update -qq

# Deploy via salt -- this runs 30docker.sls which installs:
# containerd.io, docker-ce, docker-ce-cli, docker-compose-plugin, docker-buildx-plugin
# and configures daemon.json + systemd overrides
omv-salt deploy run compose

log "Docker CE installed via omv-salt"
