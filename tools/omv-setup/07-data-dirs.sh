#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
need_root

for dir in "${DATA_DIRS[@]}"; do
  path="$DATA_ROOT/$dir"

  if [[ ! -d "$path" ]]; then
    mkdir -p "$path"
    log "Created $path"
  fi

  current_owner=$(stat -c '%U:%G' "$path")
  expected="$SVC_USER:$SVC_GROUP"
  if [[ "$current_owner" != "$expected" ]]; then
    log "WARN: $path owned by $current_owner, changing to $expected"
  fi
  chown "$SVC_USER:$SVC_GROUP" "$path"
  chmod "$COMPOSE_DIR_MODE" "$path"
done

log "Data dirs ready: $DATA_ROOT/{${DATA_DIRS[*]}}"
