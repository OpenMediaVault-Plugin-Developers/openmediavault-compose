#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
need_root

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SF_UUIDS_FILE="$SCRIPT_DIR/.sf-uuids"

# Find the mount point backing DATA_ROOT
MOUNT_POINT="$(df --output=target "$DATA_ROOT" 2>/dev/null | tail -1)"
[[ -n "$MOUNT_POINT" ]] || { log "ERROR: cannot determine mount point for $DATA_ROOT"; exit 1; }

# Find the OMV mntent UUID for that mount point
find_mntentref() {
  omv_rpc "FsTab" "enumerateEntries" '{}' | python3 -c "
import sys, json
mount = '$MOUNT_POINT'.rstrip('/')
entries = json.load(sys.stdin)
for e in entries:
    if e.get('dir','').rstrip('/') == mount:
        print(e['uuid'])
        sys.exit(0)
# Fallback: try matching by prefix for nested mounts
for e in entries:
    if mount.startswith(e.get('dir','').rstrip('/')):
        print(e['uuid'])
        sys.exit(0)
sys.exit(1)
"
}

MNTENTREF="$(find_mntentref)" || { log "ERROR: no OMV filesystem entry for $MOUNT_POINT"; exit 1; }
log "Found mntentref=$MNTENTREF for $MOUNT_POINT"

# Check if a shared folder already exists by name, return its UUID or empty
sf_exists() {
  local name="$1"
  omv_rpc "ShareMgmt" "getList" '{"start":0,"limit":200}' | python3 -c "
import sys, json
data = json.load(sys.stdin)
for e in data.get('data', data if isinstance(data, list) else []):
    if e.get('name') == '$name':
        print(e['uuid'])
        sys.exit(0)
sys.exit(1)
" 2>/dev/null
}

# Register a shared folder, return its UUID
register_sf() {
  local name="$1" relpath="$2" comment="$3"
  local existing
  if existing="$(sf_exists "$name")"; then
    log "Shared folder '$name' already registered ($existing)"
    echo "$existing"
    return 0
  fi

  local result
  result=$(omv_rpc "ShareMgmt" "set" "{
    \"uuid\": \"$OMV_NEW_UUID\",
    \"name\": \"$name\",
    \"mntentref\": \"$MNTENTREF\",
    \"reldirpath\": \"$relpath/\",
    \"comment\": \"$comment\",
    \"privileges\": {\"privilege\": []}
  }")

  # Extract UUID from response
  local uuid
  uuid=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('uuid',''))" 2>/dev/null)
  if [[ -z "$uuid" ]]; then
    # Fetch it back by name
    uuid="$(sf_exists "$name")" || { log "ERROR: failed to create shared folder '$name'"; return 1; }
  fi
  log "Created shared folder '$name' -> $uuid"
  echo "$uuid"
}

# Compute relative path from mount point
rel_from_mount() {
  local full="$DATA_ROOT/$1"
  echo "${full#$MOUNT_POINT/}"
}

SF_COMPOSE_UUID="$(register_sf "compose" "$(rel_from_mount compose)" "Docker compose files")"
SF_APPDATA_UUID="$(register_sf "appdata" "$(rel_from_mount appdata)" "Docker container data")"
SF_BACKUP_UUID="$(register_sf "backup" "$(rel_from_mount backup)" "Docker backup storage")"
SF_SHARE_UUID="$(register_sf "share" "$(rel_from_mount share)" "Docker shared data")"

# Persist UUIDs for 09-configure-compose.sh
cat > "$SF_UUIDS_FILE" <<EOF
SF_COMPOSE_UUID=$SF_COMPOSE_UUID
SF_APPDATA_UUID=$SF_APPDATA_UUID
SF_BACKUP_UUID=$SF_BACKUP_UUID
SF_SHARE_UUID=$SF_SHARE_UUID
EOF

log "All shared folders registered"
