#!/usr/bin/env bash
# test-rpc.sh — Integration tests for openmediavault-compose RPC methods.
#
# Usage: sudo ./tests/test-rpc.sh
#
# Exercises all plugin RPC methods against the live OMV configuration
# database and Docker daemon.  Creates test objects (compose file, config
# snippet, dockerfile, scheduled job) and removes them on exit.
#
# Requirements:
#   - Run as root
#   - OMV with the compose plugin installed and configured
#   - The compose shared folder must already be set in plugin settings

set -uo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Must be run as root." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Colours / counters
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0
declare -a FAILED_TESTS=()

# All UI output goes to stderr so stdout can be used for JSON capture-free flow.
section() { echo -e "\n${CYAN}${BOLD}=== $* ===${NC}" >&2; }
info()    { echo -e "  ${YELLOW}»${NC} $*" >&2; }

_pass() { echo -e "  ${GREEN}PASS${NC}  $1" >&2; ((PASS++)) || true; }
_fail() {
    echo -e "  ${RED}FAIL${NC}  $1" >&2
    [ -n "${2:-}" ] && echo -e "         ${RED}→${NC} $2" >&2
    ((FAIL++)) || true
    FAILED_TESTS+=("$1")
}
_skip() { echo -e "  ${YELLOW}SKIP${NC}  $1${2:+  ($2)}" >&2; ((SKIP++)) || true; }

# ---------------------------------------------------------------------------
# RPC helpers
# ---------------------------------------------------------------------------

# Last successful RPC output is stored here.  Never call assert_rpc inside
# a $() subshell — that would prevent PASS/FAIL counter updates from
# propagating back to the parent shell.
RPC_OUT=""
# Last bg task output (set by assert_rpc_bg).
BG_OUT=""

# Assert RPC succeeds. Optional 5th arg: grep pattern that must appear.
# Result JSON is available in $RPC_OUT after the call.
assert_rpc() {
    local desc=$1 svc=$2 method=$3 params=${4:-'{}'} pattern=${5:-}
    local out ec=0
    RPC_OUT=""
    out=$(omv-rpc -u admin "$svc" "$method" "$params" 2>&1) || ec=$?
    if [ $ec -ne 0 ]; then
        _fail "$desc" "$(echo "$out" | tail -3)"
        return 1
    fi
    if [ -n "$pattern" ] && ! echo "$out" | grep -q "$pattern"; then
        _fail "$desc" "Pattern '$pattern' not found in: ${out:0:300}"
        return 1
    fi
    _pass "$desc"
    RPC_OUT="$out"
    return 0
}

# Assert RPC fails (non-zero exit or output contains Exception).
assert_rpc_fails() {
    local desc=$1 svc=$2 method=$3 params=${4:-'{}'}
    local out ec=0
    out=$(omv-rpc -u admin "$svc" "$method" "$params" 2>&1) || ec=$?
    if [ $ec -eq 0 ] && ! echo "$out" | grep -qi "exception"; then
        _fail "$desc" "Expected failure but RPC succeeded"
        return 1
    fi
    _pass "$desc"
    return 0
}

# Call a *Bg method, wait for the background task, report result.
# Optional 5th arg: grep pattern that must appear in the task output.
# Task output is always available in $BG_OUT after the call.
assert_rpc_bg() {
    local desc=$1 svc=$2 method=$3 params=${4:-'{}'} pattern=${5:-}
    local filename ec=0
    BG_OUT=""
    filename=$(omv-rpc -u admin "$svc" "$method" "$params" 2>&1) || ec=$?
    if [ $ec -ne 0 ]; then
        _fail "$desc" "Failed to start bg task: ${filename:0:200}"
        return 1
    fi
    filename=$(echo "$filename" | tr -d '"')

    # Poll with getOutput (not isRunning): isRunning deletes the status file
    # on completion, which would make a subsequent getOutput call fail.
    # getOutput returns {running, output, ...} and cleans up only after the
    # final read, so we can extract output from the loop's last response.
    local timeout=120 elapsed=0 poll_ec=0 poll_out
    while [ $elapsed -lt $timeout ]; do
        poll_out=$(omv-rpc -u admin "Exec" "getOutput" \
            "{\"filename\":\"$filename\",\"pos\":0}" 2>&1)
        poll_ec=$?
        [ $poll_ec -ne 0 ] && break
        echo "$poll_out" | grep -q '"running":true\|"running": true' || break
        sleep 2; ((elapsed += 2)) || true
    done
    if [ $elapsed -ge $timeout ]; then
        _fail "$desc" "Bg task timed out after ${timeout}s"
        return 1
    fi
    if [ $poll_ec -ne 0 ]; then
        local err
        err=$(echo "$poll_out" | python3 -c \
            "import sys,json; d=json.load(sys.stdin); e=d.get('error') or {}; print(e.get('message', str(d))[:300])" \
            2>/dev/null || echo "${poll_out:0:200}")
        _fail "$desc" "$err"
        return 1
    fi
    local content
    content=$(echo "$poll_out" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print(d.get('output',''))" \
        2>/dev/null || echo "")
    BG_OUT="$content"
    if echo "$content" | grep -q "Exception"; then
        _fail "$desc" "$(echo "$content" | grep "Exception" | head -2)"
        return 1
    fi
    if [ -n "$pattern" ] && ! echo "$content" | grep -q "$pattern"; then
        _fail "$desc" "Pattern '$pattern' not found in output"
        return 1
    fi
    _pass "$desc"
    return 0
}

# Extract a JSON field value.
json_get() { echo "$1" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$2',''))" 2>/dev/null; }
json_uuid() { json_get "$1" "uuid"; }

# Generate a random UUIDv4.
gen_uuid() { python3 -c "import uuid; print(uuid.uuid4())"; }

# The OMV sentinel UUID that signals "this is a new object" to ConfigObject::isNew().
# Defined in /etc/default/openmediavault as OMV_CONFIGOBJECT_NEW_UUID.
OMV_NEW_UUID=$(grep -oP 'OMV_CONFIGOBJECT_NEW_UUID="\K[^"]+' /etc/default/openmediavault 2>/dev/null \
    || echo "fa4b1c66-ef79-11e5-87a0-0002b3a176b4")

# Recover a UUID from a paginated list RPC by matching on a field value.
# Usage: recover_uuid_from_list <svc> <list_method> <field> <value>
recover_uuid_from_list() {
    local svc=$1 method=$2 field=$3 value=$4
    omv-rpc -u admin "$svc" "$method" \
        '{"start":0,"limit":100,"sortfield":"name","sortdir":"ASC"}' 2>/dev/null \
        | python3 -c "
import sys, json
d = json.load(sys.stdin)
rows = d.get('data', d) if isinstance(d, dict) else d
for r in rows:
    if r.get('$field') == '$value':
        print(r['uuid'])
        break
" 2>/dev/null || echo ""
}

# ---------------------------------------------------------------------------
# Tracked UUIDs — cleaned up on exit
# ---------------------------------------------------------------------------
FILE_UUID=""
CONFIG_UUID=""
DOCKERFILE_UUID=""
JOB_UUID=""
IMPORT_TMP=""
declare -a IMPORT_UUIDS=()

# Delete a named test object if it exists in a list RPC response.
# $6 is the field to match on (default: "name").
purge_by_name() {
    local svc=$1 list_method=$2 list_params=$3 delete_method=$4 name=$5 field=${6:-name}
    local existing
    existing=$(omv-rpc -u admin "$svc" "$list_method" "$list_params" 2>/dev/null \
        | python3 -c "
import sys, json
d = json.load(sys.stdin)
rows = d.get('data', d) if isinstance(d, dict) else d
for r in rows:
    if r.get('$field') == '$name':
        print(r['uuid'])
" 2>/dev/null || echo "")
    if [ -n "$existing" ]; then
        info "Pre-cleanup: removing leftover '$name' ($existing)"
        omv-rpc -u admin "$svc" "$delete_method" "{\"uuid\":\"$existing\"}" >/dev/null 2>&1 || true
    fi
}

pre_cleanup() {
    local list='{"start":0,"limit":100,"sortfield":"name","sortdir":"ASC"}'
    purge_by_name "Compose" "getFileList"       "$list" "deleteFile"       "omvtest_compose"
    purge_by_name "Compose" "getConfigList"     "$list" "deleteConfig"     "omvtest_config"
    purge_by_name "Compose" "getDockerfileList" "$list" "deleteDockerfile" "omvtest_dockerfile"
    # Jobs don't have a "name" field — match on "comment" instead
    local job_list='{"start":0,"limit":100,"sortfield":"execution","sortdir":"ASC"}'
    purge_by_name "Compose" "getJobList" "$job_list" "deleteJob" "omvtest_job" "comment"
    # Remove any leftover compose files from a previous import test run
    local stale
    stale=$(omv-rpc -u admin "Compose" "getFileList" "$list" 2>/dev/null \
        | python3 -c "
import sys, json
d = json.load(sys.stdin)
rows = d.get('data', d) if isinstance(d, dict) else d
for r in rows:
    if r.get('name','').startswith('omvtest_import_'):
        print(r['uuid'])
" 2>/dev/null || true)
    for uuid in $stale; do
        info "Pre-cleanup: removing leftover import test file ($uuid)"
        omv-rpc -u admin "Compose" "deleteFile" "{\"uuid\":\"$uuid\"}" >/dev/null 2>&1 || true
    done
    # Remove leftover temp dir
    rm -rf /tmp/omvtest_import.*  2>/dev/null || true
}

cleanup() {
    section "Cleanup"
    if [ -n "$JOB_UUID" ]; then
        info "Deleting test job $JOB_UUID"
        omv-rpc -u admin "Compose" "deleteJob" "{\"uuid\":\"$JOB_UUID\"}" >/dev/null 2>&1 || true
    fi
    if [ -n "$CONFIG_UUID" ]; then
        info "Deleting test config snippet $CONFIG_UUID"
        omv-rpc -u admin "Compose" "deleteConfig" "{\"uuid\":\"$CONFIG_UUID\"}" >/dev/null 2>&1 || true
    fi
    if [ -n "$DOCKERFILE_UUID" ]; then
        info "Deleting test dockerfile $DOCKERFILE_UUID"
        omv-rpc -u admin "Compose" "deleteDockerfile" "{\"uuid\":\"$DOCKERFILE_UUID\"}" >/dev/null 2>&1 || true
    fi
    if [ -n "$FILE_UUID" ]; then
        info "Deleting test compose file $FILE_UUID"
        omv-rpc -u admin "Compose" "deleteFile" "{\"uuid\":\"$FILE_UUID\"}" >/dev/null 2>&1 || true
    fi
    for uuid in "${IMPORT_UUIDS[@]}"; do
        info "Deleting imported test file $uuid"
        omv-rpc -u admin "Compose" "deleteFile" "{\"uuid\":\"$uuid\"}" >/dev/null 2>&1 || true
    done
    if [ -n "$IMPORT_TMP" ]; then
        info "Removing temp import dir $IMPORT_TMP"
        rm -rf "$IMPORT_TMP"
    fi
    echo "" >&2
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Minimal compose YAML used in tests
# ---------------------------------------------------------------------------
TEST_COMPOSE_BODY='services:
  hello:
    image: hello-world
    restart: unless-stopped'

TEST_COMPOSE_ENV='# test env'

# ---------------------------------------------------------------------------
# Pre-cleanup: remove any leftover objects from a previous failed run
# ---------------------------------------------------------------------------
section "Pre-cleanup"
pre_cleanup

# ---------------------------------------------------------------------------
# 1. Settings
# ---------------------------------------------------------------------------
section "Settings"

assert_rpc "get settings" "Compose" "get" '{}'
assert_rpc "get settings returns sharedfolderref" "Compose" "get" '{}' '"sharedfolderref"'

# Round-trip set: read current settings and write them back
SETTINGS="$RPC_OUT"
if [ -n "$SETTINGS" ]; then
    SET_PARAMS=$(echo "$SETTINGS" | python3 -c "
import sys, json
d = json.load(sys.stdin)
keep = [
    'sharedfolderref','composeowner','composegroup','mode','fileperms',
    'datasharedfolderref','backupsharedfolderref','backupmaxsize','backupbackend',
    'borgkeep','borgencryption','borgpassphrase','dockerStorage','dockersharedfolderref',
    'logmaxsize','liverestore','createsymlinks','podmanStorage','podmansharedfolderref',
    'urlHostname','cachetimefiles','cachetimeservices','cachetimestats',
    'cachetimeimages','cachetimenetworks','cachetimevolumes','cachetimecontainers',
    'showcmd','podman','runconfig',
]
out = {k: d[k] for k in keep if k in d}
print(json.dumps(out))
" 2>/dev/null)
    if [ -n "$SET_PARAMS" ]; then
        assert_rpc "set settings (round-trip)" "Compose" "set" "$SET_PARAMS"
    fi
fi

# ---------------------------------------------------------------------------
# 2. Compose files — CRUD
# ---------------------------------------------------------------------------
section "Compose Files"

assert_rpc "getFileList" "Compose" "getFileList" \
    '{"start":0,"limit":25,"sortfield":"name","sortdir":"ASC"}' '"total"'

assert_rpc_bg "getFileListBg" "Compose" "getFileListBg" \
    '{"start":0,"limit":25,"sortfield":"name","sortdir":"ASC"}'

assert_rpc "getFileListSuggest" "Compose" "getFileListSuggest" '{}'

assert_rpc "enumerateFiles" "Compose" "enumerateFiles" '{}'

# Create
CREATE_PARAMS=$(python3 -c "
import json
print(json.dumps({
    'name': 'omvtest_compose',
    'description': 'RPC test compose file',
    'body': '''$TEST_COMPOSE_BODY''',
    'showenv': False,
    'env': '$TEST_COMPOSE_ENV',
    'showoverride': False,
    'override': ''
}))
")
assert_rpc "setFile (create)" "Compose" "setFile" "$CREATE_PARAMS"
FILE_UUID=$(json_uuid "$RPC_OUT")
# If the RPC failed due to a salt deploy error unrelated to our file (e.g. a
# pre-existing broken config entry), the file may still have been saved to the
# DB.  Try to recover the UUID so downstream tests can continue.
if [ -z "$FILE_UUID" ]; then
    FILE_UUID=$(recover_uuid_from_list "Compose" "getFileList" "name" "omvtest_compose")
    [ -n "$FILE_UUID" ] && info "Recovered uuid from DB after salt failure: $FILE_UUID"
fi
info "Created compose file uuid=$FILE_UUID"

if [ -n "$FILE_UUID" ]; then
    assert_rpc "getFile" "Compose" "getFile" "{\"uuid\":\"$FILE_UUID\"}" '"omvtest_compose"'

    UPDATE_PARAMS=$(python3 -c "
import json
print(json.dumps({
    'uuid': '$FILE_UUID',
    'name': 'omvtest_compose',
    'description': 'RPC test compose file - updated',
    'body': '''$TEST_COMPOSE_BODY''',
    'showenv': False,
    'env': '$TEST_COMPOSE_ENV',
    'showoverride': False,
    'override': ''
}))
")
    assert_rpc "setFile (update description)" "Compose" "setFile" "$UPDATE_PARAMS" 'updated'
else
    _skip "getFile" "no file uuid"
    _skip "setFile (update)" "no file uuid"
fi

assert_rpc_fails "setFile (missing name)" "Compose" "setFile" \
    '{"name":"","description":"","body":"","showenv":false,"env":"","showoverride":false,"override":""}'

# ---------------------------------------------------------------------------
# 3. Global environment
# ---------------------------------------------------------------------------
section "Global Environment"

assert_rpc "getGlobalEnv" "Compose" "getGlobalEnv" '{}'
ORIG_GENV="$RPC_OUT"

assert_rpc "setGlobalEnv" "Compose" "setGlobalEnv" \
    '{"enabled":false,"globalenv":"# rpc test global env\n"}'

# Restore original
if [ -n "$ORIG_GENV" ]; then
    RESTORE_GENV=$(echo "$ORIG_GENV" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(json.dumps({'enabled': d.get('enabled', False), 'globalenv': d.get('globalenv', '')}))
" 2>/dev/null)
    if [ -n "$RESTORE_GENV" ]; then
        omv-rpc -u admin "Compose" "setGlobalEnv" "$RESTORE_GENV" >/dev/null 2>&1 || true
    fi
fi

# ---------------------------------------------------------------------------
# 4. Config snippets — CRUD
# ---------------------------------------------------------------------------
section "Config Snippets"

assert_rpc "getConfigList" "Compose" "getConfigList" \
    '{"start":0,"limit":25,"sortfield":"name","sortdir":"ASC"}' '"total"'

if [ -n "$FILE_UUID" ]; then
    CONFIG_PARAMS=$(python3 -c "
import json
print(json.dumps({
    'name': 'omvtest_config',
    'description': 'RPC test config snippet',
    'fileref': '$FILE_UUID',
    'body': '# test config snippet'
}))
")
    assert_rpc "setConfig (create)" "Compose" "setConfig" "$CONFIG_PARAMS"
    CONFIG_UUID=$(json_uuid "$RPC_OUT")
    if [ -z "$CONFIG_UUID" ]; then
        CONFIG_UUID=$(recover_uuid_from_list "Compose" "getConfigList" "name" "omvtest_config")
        [ -n "$CONFIG_UUID" ] && info "Recovered uuid from DB after salt failure: $CONFIG_UUID"
    fi
    info "Created config snippet uuid=$CONFIG_UUID"

    if [ -n "$CONFIG_UUID" ]; then
        assert_rpc "getConfig" "Compose" "getConfig" "{\"uuid\":\"$CONFIG_UUID\"}" '"omvtest_config"'

        UPDATE_CONFIG=$(python3 -c "
import json
print(json.dumps({
    'uuid': '$CONFIG_UUID',
    'name': 'omvtest_config',
    'description': 'RPC test config snippet - updated',
    'fileref': '$FILE_UUID',
    'body': '# updated config snippet'
}))
")
        assert_rpc "setConfig (update)" "Compose" "setConfig" "$UPDATE_CONFIG" 'updated'
    else
        _skip "getConfig" "no config uuid"
        _skip "setConfig (update)" "no config uuid"
    fi
else
    _skip "setConfig (create)" "no file uuid for fileref"
    _skip "getConfig" "no file uuid for fileref"
    _skip "setConfig (update)" "no file uuid for fileref"
fi

assert_rpc_fails "getConfig (bad uuid)" "Compose" "getConfig" '{"uuid":"00000000-0000-0000-0000-000000000000"}'

# ---------------------------------------------------------------------------
# 5. Dockerfiles — CRUD
# ---------------------------------------------------------------------------
section "Dockerfiles"

assert_rpc "getDockerfileList" "Compose" "getDockerfileList" \
    '{"start":0,"limit":25,"sortfield":"name","sortdir":"ASC"}' '"total"'

DOCKERFILE_PARAMS=$(python3 -c "
import json
print(json.dumps({
    'name': 'omvtest_dockerfile',
    'description': 'RPC test dockerfile',
    'body': 'FROM alpine:latest\nRUN echo hello',
    'script': '',
    'scriptfile': '',
    'conf': '',
    'conffile': ''
}))
")
assert_rpc "setDockerfile (create)" "Compose" "setDockerfile" "$DOCKERFILE_PARAMS"
DOCKERFILE_UUID=$(json_uuid "$RPC_OUT")
if [ -z "$DOCKERFILE_UUID" ]; then
    DOCKERFILE_UUID=$(recover_uuid_from_list "Compose" "getDockerfileList" "name" "omvtest_dockerfile")
    [ -n "$DOCKERFILE_UUID" ] && info "Recovered uuid from DB after salt failure: $DOCKERFILE_UUID"
fi
info "Created dockerfile uuid=$DOCKERFILE_UUID"

if [ -n "$DOCKERFILE_UUID" ]; then
    assert_rpc "getDockerfile" "Compose" "getDockerfile" "{\"uuid\":\"$DOCKERFILE_UUID\"}" '"omvtest_dockerfile"'

    UPDATE_DOCKERFILE=$(python3 -c "
import json
print(json.dumps({
    'uuid': '$DOCKERFILE_UUID',
    'name': 'omvtest_dockerfile',
    'description': 'RPC test dockerfile - updated',
    'body': 'FROM alpine:latest\nRUN echo updated',
    'script': '',
    'scriptfile': '',
    'conf': '',
    'conffile': ''
}))
")
    assert_rpc "setDockerfile (update)" "Compose" "setDockerfile" "$UPDATE_DOCKERFILE" 'updated'
else
    _skip "getDockerfile" "no dockerfile uuid"
    _skip "setDockerfile (update)" "no dockerfile uuid"
fi

# ---------------------------------------------------------------------------
# 6. Scheduled jobs — CRUD (includes excludefilter)
# ---------------------------------------------------------------------------
section "Scheduled Jobs"

assert_rpc "getJobList" "Compose" "getJobList" \
    '{"start":0,"limit":25,"sortfield":"execution","sortdir":"ASC"}' '"total"'

JOB_PARAMS=$(python3 -c "
import json
print(json.dumps({
    'uuid': '$OMV_NEW_UUID',
    'enable': False,
    'filter': '*',
    'excludefilter': 'nextcloud',
    'backup': True,
    'prebackup': '',
    'postbackup': '',
    'maintenance': True,
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
    'verbose': True,
    'comment': 'omvtest_job',
    'excludes': '',
    'execution': 'weekly',
    'minute': ['0'],
    'everynminute': False,
    'hour': ['2'],
    'everynhour': False,
    'dayofmonth': ['*'],
    'everyndayofmonth': False,
    'month': ['*'],
    'dayofweek': ['*']
}))
")
assert_rpc "setJob (create with excludefilter)" "Compose" "setJob" "$JOB_PARAMS"
JOB_UUID=$(json_uuid "$RPC_OUT")
info "Created job uuid=$JOB_UUID"

if [ -n "$JOB_UUID" ]; then
    assert_rpc "getJob" "Compose" "getJob" "{\"uuid\":\"$JOB_UUID\"}"
    JOB="$RPC_OUT"

    # Verify excludefilter was saved correctly
    saved_ef=$(json_get "$JOB" "excludefilter")
    if [ "$saved_ef" = "nextcloud" ]; then
        _pass "excludefilter saved correctly"
    else
        _fail "excludefilter saved correctly" "expected 'nextcloud', got '$saved_ef'"
    fi

    # Verify filter round-trip (* is stored as empty string)
    saved_filter=$(json_get "$JOB" "filter")
    if [ "$saved_filter" = "" ] || [ "$saved_filter" = "*" ]; then
        _pass "filter '*' stored correctly"
    else
        _fail "filter '*' stored correctly" "got '$saved_filter'"
    fi

    # Update — comma-separated excludefilter
    UPDATE_JOB=$(python3 -c "
import json
print(json.dumps({
    'uuid': '$JOB_UUID',
    'enable': False,
    'filter': '*',
    'excludefilter': 'nextcloud,plex',
    'backup': True,
    'prebackup': '',
    'postbackup': '',
    'maintenance': True,
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
    'verbose': True,
    'comment': 'omvtest_job',
    'excludes': '',
    'execution': 'daily',
    'minute': ['0'],
    'everynminute': False,
    'hour': ['3'],
    'everynhour': False,
    'dayofmonth': ['*'],
    'everyndayofmonth': False,
    'month': ['*'],
    'dayofweek': ['*']
}))
")
    assert_rpc "setJob (update excludefilter)" "Compose" "setJob" "$UPDATE_JOB"
    saved_ef2=$(json_get "$RPC_OUT" "excludefilter")
    if [ "$saved_ef2" = "nextcloud,plex" ]; then
        _pass "excludefilter comma list saved correctly"
    else
        _fail "excludefilter comma list saved correctly" "expected 'nextcloud,plex', got '$saved_ef2'"
    fi
else
    _skip "getJob" "no job uuid"
    _skip "excludefilter saved correctly" "no job uuid"
    _skip "filter '*' stored correctly" "no job uuid"
    _skip "setJob (update excludefilter)" "no job uuid"
    _skip "excludefilter comma list saved correctly" "no job uuid"
fi

# Validation: no action selected
assert_rpc_fails "setJob (no action)" "Compose" "setJob" "$(python3 -c "
import json, uuid
print(json.dumps({
    'uuid': str(uuid.uuid4()),
    'enable': False, 'filter': '', 'excludefilter': '',
    'backup': False, 'prebackup': '', 'postbackup': '',
    'maintenance': False, 'cstate': False, 'cbuild': False,
    'update': False, 'prune': False, 'filestart': False,
    'filestop': False, 'filebuild': False, 'filepull': False,
    'filenocache': False, 'fileprunebuilder': False,
    'sendemail': False, 'emailonerror': False,
    'verbose': True, 'comment': '', 'excludes': '',
    'execution': 'daily',
    'minute': ['0'], 'everynminute': False,
    'hour': ['2'], 'everynhour': False,
    'dayofmonth': ['*'], 'everyndayofmonth': False,
    'month': ['*'], 'dayofweek': ['*']
}))")"

assert_rpc_fails "deleteJob (bad uuid)" "Compose" "deleteJob" '{"uuid":"00000000-0000-0000-0000-000000000000"}'

# ---------------------------------------------------------------------------
# 7. Docker resource lists (read-only, may return empty)
# ---------------------------------------------------------------------------
section "Docker Resource Lists"

assert_rpc "getServicesList" "Compose" "getServicesList" \
    '{"start":0,"limit":25,"sortfield":"name","sortdir":"ASC"}' '"total"'

assert_rpc_bg "getServicesListBg" "Compose" "getServicesListBg" \
    '{"start":0,"limit":25,"sortfield":"name","sortdir":"ASC"}'

assert_rpc "getContainerList" "Compose" "getContainerList" \
    '{"start":0,"limit":25,"sortfield":"name","sortdir":"ASC"}' '"total"'

assert_rpc_bg "getContainerListBg" "Compose" "getContainerListBg" \
    '{"start":0,"limit":25,"sortfield":"name","sortdir":"ASC"}'

assert_rpc "enumerateContainers" "Compose" "enumerateContainers" '{}'

assert_rpc "getVolumes" "Compose" "getVolumes" \
    '{"start":0,"limit":25,"sortfield":"name","sortdir":"ASC"}' '"total"'

assert_rpc_bg "getVolumesBg" "Compose" "getVolumesBg" \
    '{"start":0,"limit":25,"sortfield":"name","sortdir":"ASC"}'

assert_rpc "getNetworks" "Compose" "getNetworks" \
    '{"start":0,"limit":25,"sortfield":"name","sortdir":"ASC"}' '"total"'

assert_rpc_bg "getNetworksBg" "Compose" "getNetworksBg" \
    '{"start":0,"limit":25,"sortfield":"name","sortdir":"ASC"}'

assert_rpc "enumerateNetworkList" "Compose" "enumerateNetworkList" '{}'

assert_rpc "getImages" "Compose" "getImages" \
    '{"start":0,"limit":25,"sortfield":"repository","sortdir":"ASC"}' '"total"'

assert_rpc_bg "getImagesBg" "Compose" "getImagesBg" \
    '{"start":0,"limit":25,"sortfield":"repository","sortdir":"ASC"}'

assert_rpc "getContainers" "Compose" "getContainers" '{}'

# ---------------------------------------------------------------------------
# 8. Stats
# ---------------------------------------------------------------------------
section "Stats"

assert_rpc "getStats" "Compose" "getStats" '{}'
assert_rpc_bg "getStatsBg" "Compose" "getStatsBg" '{}'

# ---------------------------------------------------------------------------
# 9. Cache
# ---------------------------------------------------------------------------
section "Cache"

assert_rpc "clearCacheFiles" "Compose" "clearCacheFiles" '{}'

# ---------------------------------------------------------------------------
# 10. Restore list / Repo list (read-only)
# ---------------------------------------------------------------------------
section "Restore & Repo"

# getRestoreList requires the backup shared folder to be configured.
# It returns a plain JSON array (not a paginated {total,data} object).
restore_out=$(omv-rpc -u admin "Compose" "getRestoreList" \
    '{"start":0,"limit":25,"sortfield":"name","sortdir":"ASC"}' 2>&1)
restore_ec=$?
if [ $restore_ec -ne 0 ] || echo "$restore_out" | grep -qi "exception\|shared folder"; then
    _skip "getRestoreList" "backup shared folder not configured or error"
elif echo "$restore_out" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
    _pass "getRestoreList"
else
    _fail "getRestoreList" "${restore_out:0:200}"
fi

assert_rpc "getRepoList" "Compose" "getRepoList" \
    '{"start":0,"limit":25,"sortfield":"server","sortdir":"ASC"}' '"total"'

assert_rpc_fails "deleteBackup (bad uuid)" "Compose" "deleteBackup" '{"uuid":"00000000-0000-0000-0000-000000000000"}'

# ---------------------------------------------------------------------------
# 11. Compose file — doCommand (config only, non-destructive)
# ---------------------------------------------------------------------------
section "Compose file commands"

if [ -n "$FILE_UUID" ]; then
    assert_rpc_bg "doCommand (config)" "Compose" "doCommand" \
        "{\"uuid\":\"$FILE_UUID\",\"command\":\"config\",\"command2\":\"\"}"
else
    _skip "doCommand (config)" "no file uuid"
fi

# ---------------------------------------------------------------------------
# 12. Import features
# ---------------------------------------------------------------------------
section "Import features"

# Build a temp tree that exercises all import code paths:
#
#   $IMPORT_TMP/
#     omvtest_import_stack1/compose.yml          — modern filename
#     omvtest_import_stack2/docker-compose.yml   — legacy filename
#     omvtest_import_stack3/docker-compose.yaml  — .yaml extension
#     omvtest_import_readme/compose.yml          — has README.md for description
#       README.md
#     nested/
#       omvtest_import_stack4/compose.yml        — recursive scan
#     omvtest_import_one/compose.yml             — for doImportExistingOne

IMPORT_TMP=$(mktemp -d /tmp/omvtest_import.XXXXXX)
info "Import temp dir: $IMPORT_TMP"

_make_stack() {
    local dir="$1"
    local file="$2"
    mkdir -p "$dir"
    cat > "$dir/$file" <<'YAML'
services:
  hello:
    image: hello-world
YAML
}

_make_stack "$IMPORT_TMP/omvtest_import_stack1"  "compose.yml"
_make_stack "$IMPORT_TMP/omvtest_import_stack2"  "docker-compose.yml"
_make_stack "$IMPORT_TMP/omvtest_import_stack3"  "docker-compose.yaml"
_make_stack "$IMPORT_TMP/omvtest_import_readme"  "compose.yml"
cat > "$IMPORT_TMP/omvtest_import_readme/README.md" <<'MD'
# My Test Stack
This is a test stack for verifying README description extraction.
MD
_make_stack "$IMPORT_TMP/nested/omvtest_import_stack4" "compose.yml"
# omvtest_import_one is created after the bulk-import tests so that
# doImportExistingFolder doesn't pick it up and cause doImportExistingOne
# to see it as already-existing (outputting "Skipping" instead of "Imported:").

# --- doPreviewImportFolder: dry run, nothing should be imported -------------

assert_rpc_bg "doPreviewImportFolder shows WOULD IMPORT" \
    "Compose" "doPreviewImportFolder" \
    "{\"path\":\"$IMPORT_TMP\"}" "WOULD IMPORT"

# Count files before import — preview must not have changed anything.
count_before=$(omv-rpc -u admin "Compose" "getFileList" \
    '{"start":0,"limit":1000,"sortfield":"name","sortdir":"ASC"}' 2>/dev/null \
    | python3 -c "
import sys, json
d = json.load(sys.stdin)
rows = d.get('data', d) if isinstance(d, dict) else d
print(sum(1 for r in rows if r.get('name','').startswith('omvtest_import_')))
" 2>/dev/null || echo "0")
if [ "$count_before" -eq 0 ]; then
    _pass "doPreviewImportFolder did not import anything"
else
    _fail "doPreviewImportFolder did not import anything" \
          "found $count_before omvtest_import_* files after preview"
fi

# --- doImportExistingFolder: recursive import --------------------------------

assert_rpc_bg "doImportExistingFolder imports stacks" \
    "Compose" "doImportExistingFolder" \
    "{\"path\":\"$IMPORT_TMP\"}" "Imported:"

# Collect the UUIDs of everything we just imported for cleanup.
while IFS= read -r uuid; do
    [ -n "$uuid" ] && IMPORT_UUIDS+=("$uuid")
done < <(omv-rpc -u admin "Compose" "getFileList" \
    '{"start":0,"limit":1000,"sortfield":"name","sortdir":"ASC"}' 2>/dev/null \
    | python3 -c "
import sys, json
d = json.load(sys.stdin)
rows = d.get('data', d) if isinstance(d, dict) else d
for r in rows:
    if r.get('name','').startswith('omvtest_import_'):
        print(r['uuid'])
" 2>/dev/null || true)

# Check each expected stack was imported.
for name in omvtest_import_stack1 omvtest_import_stack2 omvtest_import_stack3; do
    uuid=$(recover_uuid_from_list "Compose" "getFileList" "name" "$name")
    if [ -n "$uuid" ]; then
        _pass "$name imported"
    else
        _fail "$name imported" "not found in file list"
    fi
done

# Check recursive scanning found the nested stack.
nested_uuid=$(recover_uuid_from_list "Compose" "getFileList" "name" "omvtest_import_stack4")
if [ -n "$nested_uuid" ]; then
    _pass "recursive scan found omvtest_import_stack4"
else
    _fail "recursive scan found omvtest_import_stack4" "not found in file list"
fi

# Check README description was used for omvtest_import_readme.
readme_uuid=$(recover_uuid_from_list "Compose" "getFileList" "name" "omvtest_import_readme")
if [ -n "$readme_uuid" ]; then
    readme_desc=$(omv-rpc -u admin "Compose" "getFile" "{\"uuid\":\"$readme_uuid\"}" 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('description',''))" 2>/dev/null || echo "")
    if echo "$readme_desc" | grep -q "test stack"; then
        _pass "README description extracted for omvtest_import_readme"
    else
        _fail "README description extracted for omvtest_import_readme" \
              "description was: '$readme_desc'"
    fi
else
    _skip "README description extracted" "omvtest_import_readme not imported"
fi

# --- doImportExistingFolder: re-run should skip all duplicates ---------------

assert_rpc_bg "doImportExistingFolder skips duplicates" \
    "Compose" "doImportExistingFolder" \
    "{\"path\":\"$IMPORT_TMP\"}" "Skipping"

if echo "$BG_OUT" | grep -q "0 imported"; then
    _pass "doImportExistingFolder reported 0 imported on second run"
else
    _fail "doImportExistingFolder reported 0 imported on second run" \
          "output: ${BG_OUT:0:200}"
fi

# --- doPreviewImportFolder: after import, all should show SKIP ---------------

assert_rpc_bg "doPreviewImportFolder shows SKIP after import" \
    "Compose" "doPreviewImportFolder" \
    "{\"path\":\"$IMPORT_TMP\"}" "SKIP - already exists"

# --- doImportExistingOne: import a single stack ------------------------------

# Create omvtest_import_one here (not at the top) so doImportExistingFolder
# above doesn't include it in the bulk import, keeping this a fresh import.
_make_stack "$IMPORT_TMP/omvtest_import_one" "compose.yml"

assert_rpc_bg "doImportExistingOne imports stack" \
    "Compose" "doImportExistingOne" \
    "{\"path\":\"$IMPORT_TMP/omvtest_import_one\"}" "Imported:"

one_uuid=$(recover_uuid_from_list "Compose" "getFileList" "name" "omvtest_import_one")
if [ -n "$one_uuid" ]; then
    _pass "omvtest_import_one found in file list after doImportExistingOne"
    IMPORT_UUIDS+=("$one_uuid")
else
    _fail "omvtest_import_one found in file list after doImportExistingOne" "not found"
fi

# --- doImportExistingOne: duplicate is reported, not an error ----------------

assert_rpc_bg "doImportExistingOne skips duplicate" \
    "Compose" "doImportExistingOne" \
    "{\"path\":\"$IMPORT_TMP/omvtest_import_one\"}" "Skipping"

# --- doImportExistingOne: file path is stripped to its parent dir ------------

_make_stack "$IMPORT_TMP/omvtest_import_strip" "compose.yml"
assert_rpc_bg "doImportExistingOne strips file path to directory" \
    "Compose" "doImportExistingOne" \
    "{\"path\":\"$IMPORT_TMP/omvtest_import_strip/compose.yml\"}" "Imported:"

strip_uuid=$(recover_uuid_from_list "Compose" "getFileList" "name" "omvtest_import_strip")
if [ -n "$strip_uuid" ]; then
    _pass "omvtest_import_strip imported after file path was stripped"
    IMPORT_UUIDS+=("$strip_uuid")
else
    _fail "omvtest_import_strip imported after file path was stripped" "not found"
fi

# --- doImportPortainerStacks: graceful error on unreachable host -------------

assert_rpc_bg "doImportPortainerStacks handles unreachable host" \
    "Compose" "doImportPortainerStacks" \
    '{"url":"https://invalid-host-omvtest.local:9443","apikey":"ptr_test","username":"","password":"","sslverify":"false"}' \
    "Error:"

# ---------------------------------------------------------------------------
# 13. Delete test objects (also done by cleanup trap, but verify RPCs work)
# ---------------------------------------------------------------------------
section "Delete test objects"

if [ -n "$JOB_UUID" ]; then
    assert_rpc "deleteJob" "Compose" "deleteJob" "{\"uuid\":\"$JOB_UUID\"}" && JOB_UUID=""
fi

if [ -n "$CONFIG_UUID" ]; then
    assert_rpc "deleteConfig" "Compose" "deleteConfig" "{\"uuid\":\"$CONFIG_UUID\"}" && CONFIG_UUID=""
fi

if [ -n "$DOCKERFILE_UUID" ]; then
    assert_rpc "deleteDockerfile" "Compose" "deleteDockerfile" "{\"uuid\":\"$DOCKERFILE_UUID\"}" && DOCKERFILE_UUID=""
fi

if [ -n "$FILE_UUID" ]; then
    assert_rpc "deleteFile" "Compose" "deleteFile" "{\"uuid\":\"$FILE_UUID\"}" && FILE_UUID=""
fi

assert_rpc_fails "deleteFile (bad uuid)" "Compose" "deleteFile" '{"uuid":"00000000-0000-0000-0000-000000000000"}'

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "" >&2
echo -e "${BOLD}Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}, ${YELLOW}${SKIP} skipped${NC}" >&2
if [ ${#FAILED_TESTS[@]} -gt 0 ]; then
    echo -e "${RED}Failed tests:${NC}" >&2
    for t in "${FAILED_TESTS[@]}"; do
        echo -e "  - $t" >&2
    done
    exit 1
fi
exit 0
