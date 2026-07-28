#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
need_root

# Check if a job with our comment marker already exists
job_exists() {
  local marker="$1"
  omv_rpc "Compose" "getJobList" '{"start":0,"limit":100,"sortfield":"comment","sortdir":"ASC"}' | \
    python3 -c "
import sys, json
data = json.load(sys.stdin)
items = data.get('data', data if isinstance(data, list) else [])
for e in items:
    if e.get('comment','') == '$marker':
        sys.exit(0)
sys.exit(1)
" 2>/dev/null
}

create_job() {
  local comment="$1"
  local json_override="$2"

  if job_exists "$comment"; then
    log "Job '$comment' already exists"
    return 0
  fi

  # Base template with all required fields
  local params
  params=$(python3 -c "
import json
base = {
    'uuid': '$OMV_NEW_UUID',
    'enable': True,
    'filter': '*',
    'excludefilter': '',
    'backup': False,
    'prebackup': '',
    'postbackup': '',
    'maintenance': False,
    'cstate': False,
    'cbuild': False,
    'update': False,
    'prune': False,
    'filestart': False,
    'filestop': False,
    'filebuild': False,
    'filepull': False,
    'filenocache': False,
    'fileprunebuilder': False,
    'sendemail': False,
    'emailonerror': False,
    'verbose': False,
    'skipstartstop': False,
    'comment': '$comment',
    'excludes': '',
    'execution': 'daily',
    'minute': ['0'],
    'everynminute': False,
    'hour': ['2'],
    'everynhour': False,
    'dayofmonth': ['*'],
    'everyndayofmonth': False,
    'month': ['*'],
    'dayofweek': ['*'],
}
override = json.loads('$json_override')
base.update(override)
print(json.dumps(base))
")

  omv_rpc "Compose" "setJob" "$params" >/dev/null
  log "Created job '$comment'"
}

# Daily backup at 2:00 AM
create_job "omv-setup: daily backup" '{"backup":true,"maintenance":true,"hour":["2"],"minute":["0"]}'

# Weekly update check on Sundays at 3:00 AM
create_job "omv-setup: weekly update" '{"update":true,"execution":"weekly","hour":["3"],"minute":["0"],"dayofweek":["7"]}'

# Weekly prune on Sundays at 4:00 AM
create_job "omv-setup: weekly prune" '{"prune":true,"execution":"weekly","hour":["4"],"minute":["0"],"dayofweek":["7"]}'

log "Scheduled jobs configured"
