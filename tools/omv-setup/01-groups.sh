#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
need_root

# System docker group (for /var/run/docker.sock access)
if getent group "$DOCKER_GROUP" >/dev/null 2>&1; then
  log "Group '$DOCKER_GROUP' already exists"
else
  groupadd "$DOCKER_GROUP"
  log "Created group '$DOCKER_GROUP'"
fi

# Organizational group (for data directory ownership)
if getent group "$SVC_GROUP" >/dev/null 2>&1; then
  log "Group '$SVC_GROUP' already exists"
else
  groupadd "$SVC_GROUP"
  log "Created group '$SVC_GROUP'"
fi
