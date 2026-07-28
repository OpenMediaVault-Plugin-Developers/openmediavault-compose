#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
need_root

log "Applying configuration via omv-salt..."
omv-salt deploy run compose
log "Deploy complete -- all config applied"
