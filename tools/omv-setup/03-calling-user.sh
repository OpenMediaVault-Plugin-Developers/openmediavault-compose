#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
need_root

if [[ "$CALLING_USER" == "root" ]]; then
  log "Running as root directly, skipping group additions"
  exit 0
fi

for grp in "$DOCKER_GROUP" "$SVC_GROUP"; do
  if id -nG "$CALLING_USER" | grep -qw "$grp"; then
    log "$CALLING_USER already in $grp"
  else
    usermod -aG "$grp" "$CALLING_USER"
    log "Added $CALLING_USER to $grp (re-login to take effect)"
  fi
done
