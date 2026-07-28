#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
need_root

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SF_UUIDS_FILE="$SCRIPT_DIR/.sf-uuids"

[[ -f "$SF_UUIDS_FILE" ]] || { log "ERROR: run 08-register-shares.sh first"; exit 1; }
source "$SF_UUIDS_FILE"

# Read current compose settings
CURRENT=$(omv_rpc "Compose" "get" '{}')

# Check which fields would change (only flag non-empty -> different)
CHANGES=$(python3 -c "
import sys, json
c = json.loads(sys.stdin.read())
desired = {
    'sharedfolderref': '$SF_COMPOSE_UUID',
    'datasharedfolderref': '$SF_APPDATA_UUID',
    'backupsharedfolderref': '$SF_BACKUP_UUID',
    'composeowner': '$SVC_USER',
    'composegroup': '$SVC_GROUP',
}
changes = []
for k, v in desired.items():
    cur = c.get(k, '')
    if cur and cur != v:
        changes.append(f'  {k}: {cur} -> {v}')
print('\n'.join(changes))
" <<< "$CURRENT")

if [[ -n "$CHANGES" ]]; then
  log "The following settings would change:"
  echo "$CHANGES"
  if [[ "${OMV_FORCE:-}" == "1" ]]; then
    log "OMV_FORCE=1, applying..."
  elif [[ "${OMV_NONINTERACTIVE:-}" == "1" ]]; then
    log "OMV_NONINTERACTIVE=1, skipping overwrites"
    exit 0
  else
    read -rp "[omv-setup] Apply these changes? [y/N] " answer
    [[ "$answer" =~ ^[Yy] ]] || { log "Skipped"; exit 0; }
  fi
fi

# Apply: read-modify-write
UPDATED=$(python3 -c "
import sys, json
c = json.loads(sys.stdin.read())
c['sharedfolderref'] = '$SF_COMPOSE_UUID'
c['datasharedfolderref'] = '$SF_APPDATA_UUID'
c['backupsharedfolderref'] = '$SF_BACKUP_UUID'
c['composeowner'] = '$SVC_USER'
c['composegroup'] = '$SVC_GROUP'
print(json.dumps(c))
" <<< "$CURRENT")

omv_rpc "Compose" "set" "$UPDATED"
log "Compose settings updated: owner=$SVC_USER, group=$SVC_GROUP"
