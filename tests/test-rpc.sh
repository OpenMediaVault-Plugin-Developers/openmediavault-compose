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
#
# Optional environment:
#   OMVTEST_DESTRUCTIVE=1         also run RPCs that affect the whole system:
#                                 doPrune (network prune), doDownAll (stops
#                                 every stack), restartDocker, enableDockerRepo
#                                 and doGit init (creates a git repo in the
#                                 compose shared folder)
#   OMVTEST_REINSTALL_DOCKER=1    also run reinstallDocker (purges and
#                                 reinstalls the docker packages)

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
# Optional 5th arg: case-insensitive grep pattern that must appear in the
# error output. Optional 6th arg: user to call the RPC as (default: admin).
assert_rpc_fails() {
    local desc=$1 svc=$2 method=$3 params=${4:-'{}'} pattern=${5:-} user=${6:-admin}
    local out ec=0
    out=$(omv-rpc -u "$user" "$svc" "$method" "$params" 2>&1) || ec=$?
    if [ $ec -eq 0 ] && ! echo "$out" | grep -qi "exception"; then
        _fail "$desc" "Expected failure but RPC succeeded"
        return 1
    fi
    if [ -n "$pattern" ] && ! echo "$out" | grep -qi -- "$pattern"; then
        _fail "$desc" "Failed, but '$pattern' not found in: ${out:0:300}"
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

# Call a *Bg method and assert the background task fails (the bg process
# threw, so getOutput returns an error, or the output contains Exception).
# The error message and task output are available in $BG_OUT afterwards.
assert_rpc_bg_fails() {
    local desc=$1 svc=$2 method=$3 params=${4:-'{}'}
    local filename ec=0
    BG_OUT=""
    filename=$(omv-rpc -u admin "$svc" "$method" "$params" 2>&1) || ec=$?
    if [ $ec -ne 0 ]; then
        BG_OUT="$filename"
        _pass "$desc"
        return 0
    fi
    filename=$(echo "$filename" | tr -d '"')
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
    # Decode the JSON so escaped slashes (\/) in the message are readable.
    BG_OUT=$(echo "$poll_out" | python3 -c "
import sys, json
data = sys.stdin.read()
try:
    d = json.loads(data)
except ValueError:
    print(data)
    sys.exit()
e = d.get('error') or {}
print(e.get('message', ''))
print(d.get('output', ''))
" 2>/dev/null || echo "$poll_out")
    if [ $poll_ec -ne 0 ] || echo "$poll_out" | grep -q "Exception"; then
        _pass "$desc"
        return 0
    fi
    _fail "$desc" "Expected failure but bg task succeeded"
    return 1
}

# Extract a JSON field value.
json_get() { echo "$1" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$2',''))" 2>/dev/null; }
json_uuid() { json_get "$1" "uuid"; }

# Assert on-disk file $2 contains the literal string $3.
assert_file_contains() {
    local desc=$1 file=$2 needle=$3
    if [ ! -f "$file" ]; then
        _fail "$desc" "$file does not exist"
    elif grep -qF -- "$needle" "$file"; then
        _pass "$desc"
    else
        _fail "$desc" "expected '$needle' in $file"
    fi
}

# Assert a download RPC (getLog & co.) returns an existing temp file; the
# file is removed afterwards. Optional 5th arg: expected download filename.
assert_download() {
    local desc=$1 svc=$2 method=$3 params=$4 want=${5:-} path name
    assert_rpc "$desc" "$svc" "$method" "$params" '"filepath"' || return 1
    path=$(json_get "$RPC_OUT" "filepath")
    name=$(json_get "$RPC_OUT" "filename")
    if [ -n "$path" ] && [ -f "$path" ]; then
        _pass "$desc returns an existing file"
    else
        _fail "$desc returns an existing file" "filepath '$path' does not exist"
    fi
    if [ -n "$want" ]; then
        if [ "$name" = "$want" ]; then
            _pass "$desc filename is $want"
        else
            _fail "$desc filename is $want" "got '$name'"
        fi
    fi
    [ -n "$path" ] && rm -f "$path"
    return 0
}

# Print a setFile param object. Usage: file_params <name> <body> [env] [override]
file_params() {
    python3 - "$@" <<'PY'
import json, sys
a = sys.argv[1:] + ['', '']
print(json.dumps({
    'name': a[0], 'description': 'RPC test compose file', 'body': a[1],
    'showenv': False, 'env': a[2], 'showoverride': False, 'override': a[3],
}))
PY
}

# Create a compose file that is deleted on exit. Its uuid is in $CREATED_UUID.
# Usage: create_extra_file <desc> <name> <body> [env] [override]
CREATED_UUID=""
create_extra_file() {
    local desc=$1 name=$2
    shift 2
    CREATED_UUID=""
    assert_rpc "$desc" "Compose" "setFile" "$(file_params "$name" "$@")"
    CREATED_UUID=$(json_uuid "$RPC_OUT")
    [ -z "$CREATED_UUID" ] && CREATED_UUID=$(recover_uuid_from_list "Compose" "getFileList" "name" "$name")
    [ -n "$CREATED_UUID" ] && EXTRA_FILE_UUIDS+=("$CREATED_UUID")
}

# Print a field of the list row whose <match_field> equals <value>.
# Usage: list_field <method> <match_field> <value> <field> [params]
list_field() {
    local method=$1 mfield=$2 value=$3 field=$4
    local params=${5:-'{"start":0,"limit":1000,"sortfield":"name","sortdir":"ASC"}'}
    omv-rpc -u admin "Compose" "$method" "$params" 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
rows = d.get('data', d) if isinstance(d, dict) else d
for r in rows:
    if r.get('$mfield') == '$value':
        print(r.get('$field', '')); break
" 2>/dev/null
}

# Generate a random UUIDv4.
gen_uuid() { python3 -c "import uuid; print(uuid.uuid4())"; }

# The OMV sentinel UUID that signals "this is a new object" to ConfigObject::isNew().
# Defined in /etc/default/openmediavault as OMV_CONFIGOBJECT_NEW_UUID.
OMV_NEW_UUID=$(grep -oP 'OMV_CONFIGOBJECT_NEW_UUID="\K[^"]+' /etc/default/openmediavault 2>/dev/null \
    || echo "fa4b1c66-ef79-11e5-87a0-0002b3a176b4")

# getPath returns a JSON string, and PHP's json_encode escapes forward
# slashes (e.g. "\/srv\/..."), so a plain `tr -d '"'` leaves the backslashes
# in place. Decode it properly with python3 and strip the trailing slash.
get_sf_path() {
    omv-rpc -u admin "ShareMgmt" "getPath" "{\"uuid\":\"$1\"}" 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin).rstrip('/'))" 2>/dev/null
}

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
# Dockerfiles + images created for the multi-build tests (removed on exit).
BUILD_NAMES=(omvtest_build_a omvtest_build_b)
declare -a BUILD_UUIDS=()
IMPORT_TMP=""
declare -a IMPORT_UUIDS=()
# Container runtime CLI used for direct (non-RPC) helpers in the network tests.
# Resolved from plugin settings once they are read (docker vs podman).
RUNTIME="docker"
# Docker/Podman networks created during the network tests (removed on exit).
declare -a TEST_NETWORKS=()
# Docker/Podman volumes created during the volume tests (removed on exit).
declare -a TEST_VOLUMES=()
# Base directory for the createBindPath tests (removed on exit).
BIND_TEST_DIR="/tmp/omvtest_bindpath"
# Shared folder + compose file created for the sf-path-change regression test
# (removed on exit). SFPATH_ORIG_PATH is the shared folder's *first*
# absolute path; once its reldirpath is changed, that directory is orphaned
# on disk and must be cleaned up separately from the shared folder delete.
SFPATH_SF_UUID=""
SFPATH_COMPOSE_UUID=""
SFPATH_ORIG_PATH=""
# Compose file created for the CHANGE_TO_COMPOSE_DATA_PATH test (removed on exit).
DATAPATH_COMPOSE_UUID=""
# Dummy host interfaces created as macvlan/ipvlan parents (removed on exit).
declare -a TEST_DUMMY_IFACES=()
# Throwaway container used for the connect/disconnect tests (removed on exit).
NET_TEST_CTR=""
# Throwaway container that mounts a test volume, used to verify getVolumes maps
# volumes to the containers using them (removed on exit).
VOL_TEST_CTR=""
# Extra compose files, config snippets and dockerfiles created by the
# per-method coverage tests (removed on exit).
EXTRA_FILE_NAMES=(omvtest_ports_compose omvtest_nfp_compose
    omvtest_url_compose omvtest_example omvtest_autocompose)
EXTRA_CONFIG_NAMES=(omvtest_cfg_path omvtest_cfg_a.conf)
declare -a EXTRA_FILE_UUIDS=()
declare -a EXTRA_CONFIG_UUIDS=()
declare -a EXTRA_DOCKERFILE_UUIDS=()
# Job used for the doJob test (removed on exit).
JOB_RUN_UUID=""
# Image tags created by the doTag / doHubPush tests (removed on exit).
EXTRA_IMAGES=(omvtest_build_a:omvtest_tag 127.0.0.1:1/omvtest_build_a:omvtest
    127.0.0.1:1/omvtest_build_a:latest)
# Directory next to the backup shared folder used by the deleteBackup
# traversal test (removed on exit).
BACKUP_TRAVERSAL_DIR=""
# Non-admin username used for the RPC role checks. It does not have to exist:
# omv-rpc builds a user-role context for any name other than admin.
NONADMIN_USER="omvtest_nonadmin"

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
    purge_by_name "Compose" "getFileList"       "$list" "deleteFile"       "omvtest_sfpath_compose"
    purge_by_name "Compose" "getFileList"       "$list" "deleteFile"       "omvtest_datapath_compose"
    purge_by_name "Compose" "getConfigList"     "$list" "deleteConfig"     "omvtest_config"
    for cname in "${EXTRA_CONFIG_NAMES[@]}"; do
        purge_by_name "Compose" "getConfigList" "$list" "deleteConfig" "$cname"
    done
    for fname in "${EXTRA_FILE_NAMES[@]}"; do
        purge_by_name "Compose" "getFileList" "$list" "deleteFile" "$fname"
    done
    purge_by_name "Compose" "getDockerfileList" "$list" "deleteDockerfile" "omvtest_dfimport"
    purge_by_name "Compose" "getDockerfileList" "$list" "deleteDockerfile" "omvtest_dockerfile"
    for bname in "${BUILD_NAMES[@]}"; do
        purge_by_name "Compose" "getDockerfileList" "$list" "deleteDockerfile" "$bname"
    done
    # Shared folder used by the sf-path-change test — delete needs a
    # "recursive" param that purge_by_name does not pass, so handle it here.
    stale_sf=$(omv-rpc -u admin "ShareMgmt" "getList" "$list" 2>/dev/null \
        | python3 -c "
import sys, json
d = json.load(sys.stdin)
rows = d.get('data', d) if isinstance(d, dict) else d
for r in rows:
    if r.get('name') == 'omvtest_sfpath_download':
        print(r['uuid'])
" 2>/dev/null || true)
    if [ -n "$stale_sf" ]; then
        info "Pre-cleanup: removing leftover shared folder 'omvtest_sfpath_download' ($stale_sf)"
        omv-rpc -u admin "ShareMgmt" "delete" "{\"uuid\":\"$stale_sf\",\"recursive\":true}" >/dev/null 2>&1 || true
    fi
    # Jobs don't have a "name" field — match on "comment" instead
    local job_list='{"start":0,"limit":100,"sortfield":"execution","sortdir":"ASC"}'
    purge_by_name "Compose" "getJobList" "$job_list" "deleteJob" "omvtest_job" "comment"
    purge_by_name "Compose" "getJobList" "$job_list" "deleteJob" "omvtest_job_run" "comment"
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
    for uuid in "$JOB_UUID" "$JOB_RUN_UUID"; do
        [ -z "$uuid" ] && continue
        info "Deleting test job $uuid"
        omv-rpc -u admin "Compose" "deleteJob" "{\"uuid\":\"$uuid\"}" >/dev/null 2>&1 || true
    done
    for uuid in "$CONFIG_UUID" "${EXTRA_CONFIG_UUIDS[@]}"; do
        [ -z "$uuid" ] && continue
        info "Deleting test config snippet $uuid"
        omv-rpc -u admin "Compose" "deleteConfig" "{\"uuid\":\"$uuid\"}" >/dev/null 2>&1 || true
    done
    for uuid in "${EXTRA_DOCKERFILE_UUIDS[@]}"; do
        info "Deleting test dockerfile $uuid"
        omv-rpc -u admin "Compose" "deleteDockerfile" "{\"uuid\":\"$uuid\"}" >/dev/null 2>&1 || true
    done
    for uuid in "${EXTRA_FILE_UUIDS[@]}"; do
        info "Deleting test compose file $uuid"
        omv-rpc -u admin "Compose" "deleteFile" "{\"uuid\":\"$uuid\"}" >/dev/null 2>&1 || true
    done
    if [ -n "$DOCKERFILE_UUID" ]; then
        info "Deleting test dockerfile $DOCKERFILE_UUID"
        omv-rpc -u admin "Compose" "deleteDockerfile" "{\"uuid\":\"$DOCKERFILE_UUID\"}" >/dev/null 2>&1 || true
    fi
    for uuid in "${BUILD_UUIDS[@]}"; do
        info "Deleting multi-build test dockerfile $uuid"
        omv-rpc -u admin "Compose" "deleteDockerfile" "{\"uuid\":\"$uuid\"}" >/dev/null 2>&1 || true
    done
    for img in "${EXTRA_IMAGES[@]}" "${BUILD_NAMES[@]}"; do
        "$RUNTIME" image rm -f "$img" >/dev/null 2>&1 || true
    done
    if [ -n "$FILE_UUID" ]; then
        info "Deleting test compose file $FILE_UUID"
        omv-rpc -u admin "Compose" "deleteFile" "{\"uuid\":\"$FILE_UUID\"}" >/dev/null 2>&1 || true
    fi
    if [ -n "$SFPATH_COMPOSE_UUID" ]; then
        info "Deleting sf-path-change test compose file $SFPATH_COMPOSE_UUID"
        omv-rpc -u admin "Compose" "deleteFile" "{\"uuid\":\"$SFPATH_COMPOSE_UUID\"}" >/dev/null 2>&1 || true
    fi
    if [ -n "$DATAPATH_COMPOSE_UUID" ]; then
        info "Deleting data-path test compose file $DATAPATH_COMPOSE_UUID"
        omv-rpc -u admin "Compose" "deleteFile" "{\"uuid\":\"$DATAPATH_COMPOSE_UUID\"}" >/dev/null 2>&1 || true
    fi
    if [ -n "$SFPATH_SF_UUID" ]; then
        info "Deleting sf-path-change test shared folder $SFPATH_SF_UUID"
        omv-rpc -u admin "ShareMgmt" "delete" "{\"uuid\":\"$SFPATH_SF_UUID\",\"recursive\":true}" >/dev/null 2>&1 || true
    fi
    if [ -n "$SFPATH_ORIG_PATH" ] && [ -d "$SFPATH_ORIG_PATH" ]; then
        info "Removing orphaned original shared folder directory $SFPATH_ORIG_PATH"
        rm -rf "$SFPATH_ORIG_PATH" 2>/dev/null || true
    fi
    for uuid in "${IMPORT_UUIDS[@]}"; do
        info "Deleting imported test file $uuid"
        omv-rpc -u admin "Compose" "deleteFile" "{\"uuid\":\"$uuid\"}" >/dev/null 2>&1 || true
    done
    if [ -n "$BACKUP_TRAVERSAL_DIR" ] && [ -d "$BACKUP_TRAVERSAL_DIR" ]; then
        info "Removing deleteBackup traversal test dir $BACKUP_TRAVERSAL_DIR"
        rm -rf "$BACKUP_TRAVERSAL_DIR"
    fi
    if [ -n "$IMPORT_TMP" ]; then
        info "Removing temp import dir $IMPORT_TMP"
        rm -rf "$IMPORT_TMP"
    fi
    # Remove the volume-in-use container before its volume, otherwise the
    # 'volume rm' below fails because the volume is still mounted.
    if [ -n "$VOL_TEST_CTR" ]; then
        info "Removing volume test container $VOL_TEST_CTR"
        "$RUNTIME" rm -f "$VOL_TEST_CTR" >/dev/null 2>&1 || true
    fi
    for vol in "${TEST_VOLUMES[@]}"; do
        info "Removing test volume $vol"
        "$RUNTIME" volume rm "$vol" >/dev/null 2>&1 || true
    done
    if [ -n "$BIND_TEST_DIR" ] && [ -d "$BIND_TEST_DIR" ]; then
        info "Removing bind path test dir $BIND_TEST_DIR"
        rm -rf "$BIND_TEST_DIR" 2>/dev/null || true
    fi
    # Network test teardown — order matters: container, then networks, then the
    # dummy parent interfaces the macvlan/ipvlan networks reference.
    if [ -n "$NET_TEST_CTR" ]; then
        info "Removing network test container $NET_TEST_CTR"
        "$RUNTIME" rm -f "$NET_TEST_CTR" >/dev/null 2>&1 || true
    fi
    for net in "${TEST_NETWORKS[@]}"; do
        info "Removing test network $net"
        "$RUNTIME" network rm "$net" >/dev/null 2>&1 || true
    done
    for ifc in "${TEST_DUMMY_IFACES[@]}"; do
        info "Removing dummy interface $ifc"
        ip link del "$ifc" >/dev/null 2>&1 || true
    done
    echo "" >&2

    # Deploy pending config changes so the OMV web UI "apply changes" banner
    # does not linger after this test run. Runs detached/async so the script
    # returns promptly; --append-dirty clears the dirty-module markers (the
    # banner) once the deploy completes.
    info "Deploying pending config changes asynchronously (clears web UI banner)"
    nohup omv-salt deploy run --quiet --append-dirty >/dev/null 2>&1 &
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

        # The shared folder checks run before anything is written, so these
        # cannot change the settings.
        BAD_SET=$(echo "$SET_PARAMS" | python3 -c "
import sys, json
d = json.load(sys.stdin)
d['podmansharedfolderref'] = d.get('sharedfolderref', '')
print(json.dumps(d))")
        assert_rpc_fails "set rejects compose folder == podman folder" "Compose" "set" \
            "$BAD_SET" "must be different than podman shared folder"
        BAD_SET=$(echo "$SET_PARAMS" | python3 -c "
import sys, json
d = json.load(sys.stdin)
d['datasharedfolderref'] = d.get('sharedfolderref', '')
print(json.dumps(d))")
        assert_rpc_fails "set rejects compose folder == data folder" "Compose" "set" \
            "$BAD_SET" "must be different than data shared folder"
    fi
    # Pick the container runtime CLI the network tests use for direct calls.
    if echo "$SETTINGS" | grep -q '"podman":[[:space:]]*true'; then
        RUNTIME="podman"
    fi
fi
command -v "$RUNTIME" >/dev/null 2>&1 || info "Runtime '$RUNTIME' CLI not found — some network tests may skip"

# Absolute path of the compose shared folder.
SF_PATH=$(omv-rpc -u admin "ShareMgmt" "getPath" \
    "{\"uuid\":\"$(json_get "$SETTINGS" "sharedfolderref")\"}" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).rstrip('/'))" 2>/dev/null || echo "")
info "Compose shared folder path: ${SF_PATH:-<unknown>}"

# ---------------------------------------------------------------------------
# 2. Compose files — CRUD
# ---------------------------------------------------------------------------
section "Compose Files"

assert_rpc "getFileList" "Compose" "getFileList" \
    '{"start":0,"limit":25,"sortfield":"name","sortdir":"ASC"}' '"total"'

assert_rpc_bg "getFileListBg" "Compose" "getFileListBg" \
    '{"start":0,"limit":25,"sortfield":"name","sortdir":"ASC"}'

assert_rpc "getFileListSuggest" "Compose" "getFileListSuggest" '{}'
assert_rpc "getFileListSuggest includes '*' wildcard" "Compose" "getFileListSuggest" '{}' '"\*"'

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
# Number of git commits touching the test compose file (-1: no git repo).
git_commit_count() {
    if [ -n "$SF_PATH" ] && [ -d "$SF_PATH/.git" ]; then
        git -C "$SF_PATH" rev-list --count HEAD -- "omvtest_compose/omvtest_compose.yml" 2>/dev/null || echo 0
    else
        echo -1
    fi
}
GIT_COUNT_BEFORE=$(git_commit_count)

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

# Regression: setFile only set the compose name on update, so a new file was
# never added to the git repo of the compose shared folder.
if [ "$GIT_COUNT_BEFORE" = "-1" ]; then
    _skip "setFile (create) commits the new file to git" "compose shared folder is not a git repo"
elif [ "$(git_commit_count)" -gt "$GIT_COUNT_BEFORE" ]; then
    _pass "setFile (create) commits the new file to git"
else
    _fail "setFile (create) commits the new file to git" "no new commit for omvtest_compose/omvtest_compose.yml"
fi

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
    # An update writes the files directly instead of going through salt.
    ON_DISK_YML="$SF_PATH/omvtest_compose/omvtest_compose.yml"
    if [ -f "$ON_DISK_YML" ] && grep -qF "# RPC test compose file - updated" "$ON_DISK_YML"; then
        _pass "setFile (update) rewrites the compose file on disk"
    else
        _fail "setFile (update) rewrites the compose file on disk" "new description not in $ON_DISK_YML"
    fi
    assert_rpc_fails "setFile (duplicate name)" "Compose" "setFile" "$CREATE_PARAMS"
else
    _skip "getFile" "no file uuid"
    _skip "setFile (update)" "no file uuid"
    _skip "setFile (update) rewrites the compose file on disk" "no file uuid"
    _skip "setFile (duplicate name)" "no file uuid"
fi

assert_rpc "enumerateComposeNames" "Compose" "enumerateComposeNames" '{}' '"omvtest_compose"'
if echo "$RPC_OUT" | python3 -c "
import sys, json
names = [r['name'] for r in json.load(sys.stdin)]
sys.exit(0 if '*' not in names else 1)" 2>/dev/null; then
    _pass "enumerateComposeNames omits '*' wildcard"
else
    _fail "enumerateComposeNames omits '*' wildcard" "${RPC_OUT:0:200}"
fi

assert_rpc_fails "setFile (missing name)" "Compose" "setFile" \
    '{"name":"","description":"","body":"","showenv":false,"env":"","showoverride":false,"override":""}'

# ---------------------------------------------------------------------------
# 2b. Ports + body placeholders
# ---------------------------------------------------------------------------
section "Ports and placeholders"

PORTS_BODY='services:
  web:
    image: hello-world
    environment:
      TZ: ${{ tz }}
      PUID: ${{ uid:"root" }}
    ports:
      - "18080:80"
      - "127.0.0.1:18081:81/udp"'
create_extra_file "setFile (create, ports + tz/uid placeholders)" "omvtest_ports_compose" "$PORTS_BODY"
PORTS_UUID="$CREATED_UUID"

PORTS_YML="$SF_PATH/omvtest_ports_compose/omvtest_ports_compose.yml"
if [ -z "$PORTS_UUID" ]; then
    _skip "uid placeholder rendered on disk" "no file uuid"
    _skip "tz placeholder rendered on disk" "no file uuid"
else
    assert_file_contains "uid placeholder rendered on disk" "$PORTS_YML" "PUID: 0"
    if [ -f "$PORTS_YML" ] && ! grep -qF '${{ tz }}' "$PORTS_YML"; then
        _pass "tz placeholder rendered on disk"
    else
        _fail "tz placeholder rendered on disk" "'\${{ tz }}' still in $PORTS_YML (or file missing)"
    fi
fi

if ! php -m 2>/dev/null | grep -qix yaml; then
    for t in "getUsedPorts lists 18080/tcp" "getUsedPorts lists 127.0.0.1:18081/udp" \
        "doFindFreePorts skips used ports" "setFile resolves nfp placeholder"; do
        _skip "$t" "php yaml extension not installed"
    done
    assert_rpc "getUsedPorts" "Compose" "getUsedPorts" \
        '{"start":0,"limit":25,"sortfield":"file","sortdir":"ASC"}' '"total"'
else
    assert_rpc "getUsedPorts" "Compose" "getUsedPorts" \
        '{"start":0,"limit":1000,"sortfield":"file","sortdir":"ASC"}' '"total"'
    port_row() {
        echo "$RPC_OUT" | python3 -c "
import sys, json
rows = json.load(sys.stdin)['data']
sys.exit(0 if any(r['file'] == 'omvtest_ports_compose' and r['host_port'] == '$1'
                  and r['host_ip'] == '$2' and r['protocol'] == '$3' for r in rows) else 1)
" 2>/dev/null
    }
    if port_row 18080 "" tcp; then
        _pass "getUsedPorts lists 18080/tcp"
    else
        _fail "getUsedPorts lists 18080/tcp" "row not found"
    fi
    if port_row 18081 127.0.0.1 udp; then
        _pass "getUsedPorts lists 127.0.0.1:18081/udp"
    else
        _fail "getUsedPorts lists 127.0.0.1:18081/udp" "row not found"
    fi

    assert_rpc_bg "doFindFreePorts" "Compose" "doFindFreePorts" '{"startPort":18080}' \
        "Suggested free host ports"
    if echo "$BG_OUT" | grep -qxE '  (18080|18081)'; then
        _fail "doFindFreePorts skips used ports" "suggested a used port: $(echo "$BG_OUT" | head -5)"
    else
        _pass "doFindFreePorts skips used ports"
    fi

    # ${{ nfp: N }} is replaced with the first free port >= N when saved.
    create_extra_file "setFile (create, nfp placeholder)" "omvtest_nfp_compose" \
        'services:
  web:
    image: hello-world
    ports:
      - "${{ nfp: 18080 }}:80"'
    if [ -n "$CREATED_UUID" ]; then
        nfp_port=$(omv-rpc -u admin "Compose" "getFile" "{\"uuid\":\"$CREATED_UUID\"}" 2>/dev/null \
            | python3 -c "
import sys, json, re
m = re.search(r'\"(\d+):80\"', json.load(sys.stdin)['body'])
print(m.group(1) if m else '')" 2>/dev/null)
        if [ -n "$nfp_port" ] && [ "$nfp_port" -gt 18081 ]; then
            _pass "setFile resolves nfp placeholder ($nfp_port)"
        else
            _fail "setFile resolves nfp placeholder" "got port '$nfp_port' (expected a free port > 18081)"
        fi
    else
        _skip "setFile resolves nfp placeholder" "no file uuid"
    fi
fi
assert_rpc_bg "getUsedPortsBg" "Compose" "getUsedPortsBg" \
    '{"start":0,"limit":25,"sortfield":"file","sortdir":"ASC"}'

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
        CONFIG_PATH="$SF_PATH/omvtest_compose/omvtest_config"
        assert_file_contains "setConfig (update) writes the file on disk" \
            "$CONFIG_PATH" "# updated config snippet"
        fullpath=$(list_field "getConfigList" "name" "omvtest_config" "fullpath")
        if [ "$fullpath" = "$CONFIG_PATH" ]; then
            _pass "getConfigList reports fullpath"
        else
            _fail "getConfigList reports fullpath" "got '$fullpath', expected '$CONFIG_PATH'"
        fi
    else
        _skip "getConfig" "no config uuid"
        _skip "setConfig (update)" "no config uuid"
    fi

    # Names that would overwrite the stack's own files are refused.
    for bad in compose.override.yml omvtest_compose.yml omvtest_compose.env Dockerfile; do
        assert_rpc_fails "setConfig rejects reserved name $bad" "Compose" "setConfig" \
            "{\"name\":\"$bad\",\"description\":\"\",\"fileref\":\"$FILE_UUID\",\"body\":\"x\"}" \
            "Cannot use that filename"
    done

    # A path in the name is reduced to its basename.
    assert_rpc "setConfig strips path from name" "Compose" "setConfig" \
        "{\"name\":\"../../omvtest_cfg_path\",\"description\":\"\",\"fileref\":\"$FILE_UUID\",\"body\":\"x\"}" \
        '"name": *"omvtest_cfg_path"'
    cuuid=$(json_uuid "$RPC_OUT")
    [ -z "$cuuid" ] && cuuid=$(recover_uuid_from_list "Compose" "getConfigList" "name" "omvtest_cfg_path")
    [ -n "$cuuid" ] && EXTRA_CONFIG_UUIDS+=("$cuuid")
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
    assert_file_contains "setDockerfile (update) writes the Dockerfile on disk" \
        "$SF_PATH/omvtest_dockerfile/Dockerfile" "RUN echo updated"
else
    _skip "getDockerfile" "no dockerfile uuid"
    _skip "setDockerfile (update)" "no dockerfile uuid"
fi

# Script / conf filenames that would clash with the Dockerfile or a stack file
# are refused.
assert_rpc_fails "setDockerfile rejects script named Dockerfile" "Compose" "setDockerfile" \
    '{"name":"omvtest_dockerfile","description":"","body":"FROM scratch","script":"Dockerfile","scriptfile":"","conf":"","conffile":""}' \
    "Script filename cannot be"
assert_rpc_fails "setDockerfile rejects conf named <name>.yml" "Compose" "setDockerfile" \
    '{"name":"omvtest_dockerfile","description":"","body":"FROM scratch","script":"","scriptfile":"","conf":"omvtest_dockerfile.yml","conffile":""}' \
    "Conf filename cannot be"

# ---------------------------------------------------------------------------
# 5b. Dockerfiles — doBuild (multi-select build from the Dockerfiles tab)
# ---------------------------------------------------------------------------
# The Dockerfiles tab sends the selected rows as a comma-separated 'names'
# list with options '' / 'pull' / 'nocache'. The Dockerfiles use FROM scratch
# so the builds work offline; the COPY gives a cacheable step for the
# nocache checks.
section "Dockerfiles (multi build)"

BUILD_TESTS=(
    "doBuild (multi, 2 names)"
    "doBuild multi built omvtest_build_a"
    "doBuild multi built omvtest_build_b"
    "doBuild (multi, rebuild uses cache)"
    "doBuild (multi, nocache)"
    "doBuild nocache did not use cache"
    "doBuild (multi, pull)"
    "doBuild (legacy 'name' param)"
    "doBuild legacy 'name' param built the image"
    "doBuild (multi, tolerates spaces and empty entries)"
    "doBuild spaced names list built both images"
    "doBuild (multi, one bad name) continues"
    "doBuild multi reports error for bad name"
    "doBuild multi still built the good name"
    "doBuild (single bad name) fails"
    "doTag"
    "doTag created the new tag"
    "doDockerImageCmd inspect"
    "doDockerImageCmd rm"
    "doDockerImageCmd rm removed the tag"
    "doHubPush (name:tag) fails for unreachable registry"
    "doHubPush pushes name:tag"
    "doHubPush (no tag) fails for unreachable registry"
    "doHubPush without tag pushes imgname"
)

# True if the runtime has an image with this name.
image_exists() { "$RUNTIME" image inspect "$1" >/dev/null 2>&1; }

# BuildKit prints "CACHED"; the classic builder and podman/buildah print
# "Using cache".
BUILD_CACHE_RE='CACHED\|Using cache'

BUILD_SF_PATH="$SF_PATH"

for bname in "${BUILD_NAMES[@]}"; do
    "$RUNTIME" image rm -f "$bname" >/dev/null 2>&1 || true
    BUILD_PARAMS=$(python3 -c "
import json
print(json.dumps({
    'name': '$bname',
    'description': 'RPC test multi build',
    'body': 'FROM scratch\nCOPY Dockerfile /Dockerfile',
    'script': '',
    'scriptfile': '',
    'conf': '',
    'conffile': ''
}))
")
    assert_rpc "setDockerfile (create $bname)" "Compose" "setDockerfile" "$BUILD_PARAMS"
    buuid=$(json_uuid "$RPC_OUT")
    [ -z "$buuid" ] && buuid=$(recover_uuid_from_list "Compose" "getDockerfileList" "name" "$bname")
    [ -n "$buuid" ] && BUILD_UUIDS+=("$buuid")
done

BUILD_READY=1
if ! command -v "$RUNTIME" >/dev/null 2>&1; then
    BUILD_READY=0; BUILD_SKIP_WHY="runtime '$RUNTIME' CLI not found"
elif [ ${#BUILD_UUIDS[@]} -ne ${#BUILD_NAMES[@]} ]; then
    BUILD_READY=0; BUILD_SKIP_WHY="test dockerfiles not created"
else
    for bname in "${BUILD_NAMES[@]}"; do
        if [ ! -f "$BUILD_SF_PATH/$bname/Dockerfile" ]; then
            BUILD_READY=0; BUILD_SKIP_WHY="$BUILD_SF_PATH/$bname/Dockerfile not on disk"
        fi
    done
fi

if [ $BUILD_READY -eq 0 ]; then
    for t in "${BUILD_TESTS[@]}"; do _skip "$t" "$BUILD_SKIP_WHY"; done
else
    # --- Two names in one request: both images are built --------------------
    assert_rpc_bg "doBuild (multi, 2 names)" "Compose" "doBuild" \
        '{"names":"omvtest_build_a,omvtest_build_b","options":""}'
    for bname in "${BUILD_NAMES[@]}"; do
        if image_exists "$bname"; then
            _pass "doBuild multi built $bname"
        else
            _fail "doBuild multi built $bname" "image '$bname' not found"
        fi
    done

    # --- Rebuild: second build of unchanged Dockerfiles hits the cache -------
    assert_rpc_bg "doBuild (multi, rebuild uses cache)" "Compose" "doBuild" \
        '{"names":"omvtest_build_a,omvtest_build_b","options":""}' "$BUILD_CACHE_RE"

    # --- nocache: every build in the list ignores the cache ------------------
    assert_rpc_bg "doBuild (multi, nocache)" "Compose" "doBuild" \
        '{"names":"omvtest_build_a,omvtest_build_b","options":"nocache"}'
    if echo "$BG_OUT" | grep -q "$BUILD_CACHE_RE"; then
        _fail "doBuild nocache did not use cache" \
            "$(echo "$BG_OUT" | grep -m2 "$BUILD_CACHE_RE")"
    else
        _pass "doBuild nocache did not use cache"
    fi

    # --- pull: FROM scratch has nothing to pull, so this works offline ------
    assert_rpc_bg "doBuild (multi, pull)" "Compose" "doBuild" \
        '{"names":"omvtest_build_a,omvtest_build_b","options":"pull"}'

    # --- Backwards compatibility: single 'name' param -----------------------
    "$RUNTIME" image rm -f omvtest_build_a >/dev/null 2>&1 || true
    assert_rpc_bg "doBuild (legacy 'name' param)" "Compose" "doBuild" \
        '{"name":"omvtest_build_a","options":""}'
    if image_exists omvtest_build_a; then
        _pass "doBuild legacy 'name' param built the image"
    else
        _fail "doBuild legacy 'name' param built the image" "image omvtest_build_a not found"
    fi

    # --- names list is trimmed and empty entries dropped --------------------
    "$RUNTIME" image rm -f omvtest_build_a omvtest_build_b >/dev/null 2>&1 || true
    assert_rpc_bg "doBuild (multi, tolerates spaces and empty entries)" "Compose" "doBuild" \
        '{"names":" omvtest_build_a , ,omvtest_build_b,","options":""}'
    if image_exists omvtest_build_a && image_exists omvtest_build_b; then
        _pass "doBuild spaced names list built both images"
    else
        _fail "doBuild spaced names list built both images" "not all images built"
    fi

    # --- One failing name does not abort the rest of the list ---------------
    # Put the bad name first so the good one is only built if doBuild
    # carries on after the failure.
    "$RUNTIME" image rm -f omvtest_build_b >/dev/null 2>&1 || true
    assert_rpc_bg "doBuild (multi, one bad name) continues" "Compose" "doBuild" \
        '{"names":"omvtest_build_nonexistent,omvtest_build_b","options":""}'
    if echo "$BG_OUT" | grep -q '\*\*\* ERROR #'; then
        _pass "doBuild multi reports error for bad name"
    else
        _fail "doBuild multi reports error for bad name" "no '*** ERROR #' in output"
    fi
    if image_exists omvtest_build_b; then
        _pass "doBuild multi still built the good name"
    else
        _fail "doBuild multi still built the good name" "image omvtest_build_b not found"
    fi

    # --- A single failing name keeps the old behaviour: the task fails ------
    assert_rpc_bg_fails "doBuild (single bad name) fails" "Compose" "doBuild" \
        '{"names":"omvtest_build_nonexistent","options":""}'

    # --- doTag / doDockerImageCmd --------------------------------------------
    assert_rpc_bg "doTag" "Compose" "doTag" \
        '{"srcid":"","srcimg":"omvtest_build_a","srctag":"latest","tgtimg":"omvtest_build_a","tgttag":"omvtest_tag"}'
    if image_exists omvtest_build_a:omvtest_tag; then
        _pass "doTag created the new tag"
    else
        _fail "doTag created the new tag" "omvtest_build_a:omvtest_tag not found"
    fi
    assert_rpc_bg "doDockerImageCmd inspect" "Compose" "doDockerImageCmd" \
        '{"command":"inspect","id":"omvtest_build_a:omvtest_tag"}' "omvtest_build_a:omvtest_tag"
    assert_rpc_bg "doDockerImageCmd rm" "Compose" "doDockerImageCmd" \
        '{"command":"rm","id":"omvtest_build_a:omvtest_tag"}'
    if image_exists omvtest_build_a:omvtest_tag; then
        _fail "doDockerImageCmd rm removed the tag" "omvtest_build_a:omvtest_tag still exists"
    else
        _pass "doDockerImageCmd rm removed the tag"
    fi

    # --- doHubPush -----------------------------------------------------------
    # Push to a registry address nothing listens on, so the push fails fast
    # without network access; the error shows which image was pushed.
    "$RUNTIME" tag omvtest_build_a 127.0.0.1:1/omvtest_build_a:omvtest >/dev/null 2>&1
    "$RUNTIME" tag omvtest_build_a 127.0.0.1:1/omvtest_build_a:latest >/dev/null 2>&1
    assert_rpc_bg_fails "doHubPush (name:tag) fails for unreachable registry" "Compose" "doHubPush" \
        '{"imgname":"127.0.0.1:1/omvtest_build_a","imgtag":"omvtest"}'
    if echo "$BG_OUT" | grep -qF "push 127.0.0.1:1/omvtest_build_a:omvtest"; then
        _pass "doHubPush pushes name:tag"
    else
        _fail "doHubPush pushes name:tag" "${BG_OUT:0:300}"
    fi
    # Regression: without a tag doHubPush read the misspelled 'imgimg' param
    # and ran 'docker image push' with no image.
    assert_rpc_bg_fails "doHubPush (no tag) fails for unreachable registry" "Compose" "doHubPush" \
        '{"imgname":"127.0.0.1:1/omvtest_build_a","imgtag":""}'
    if echo "$BG_OUT" | grep -qE "push '?127\.0\.0\.1:1/omvtest_build_a'?( |$)"; then
        _pass "doHubPush without tag pushes imgname"
    else
        _fail "doHubPush without tag pushes imgname" "${BG_OUT:0:300}"
    fi
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
    'skipstartstop': False,
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

    if echo "$JOB" | python3 -c "
import sys, json
d = json.load(sys.stdin)
sys.exit(0 if d['minute'] == ['0'] and d['hour'] == ['2'] and d['maintenance'] else 1)" 2>/dev/null; then
        _pass "getJob returns schedule lists and mode flags"
    else
        _fail "getJob returns schedule lists and mode flags" "${JOB:0:300}"
    fi

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
    'skipstartstop': False,
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
    'verbose': True, 'skipstartstop': False, 'comment': '', 'excludes': '',
    'execution': 'daily',
    'minute': ['0'], 'everynminute': False,
    'hour': ['2'], 'everynhour': False,
    'dayofmonth': ['*'], 'everyndayofmonth': False,
    'month': ['*'], 'dayofweek': ['*']
}))")"

assert_rpc_fails "deleteJob (bad uuid)" "Compose" "deleteJob" '{"uuid":"00000000-0000-0000-0000-000000000000"}'

# doJob: a stop-only job filtered to the test stack, so it cannot touch any
# other stack.
if [ -n "$FILE_UUID" ]; then
    JOB_RUN_PARAMS=$(echo "$JOB_PARAMS" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for k in ('backup', 'update', 'prune', 'filestart', 'filebuild', 'filepull',
          'filenocache', 'fileprunebuilder', 'maintenance', 'cbuild'):
    d[k] = False
d.update({'cstate': True, 'filestop': True, 'filter': 'omvtest_compose',
          'excludefilter': '', 'comment': 'omvtest_job_run'})
print(json.dumps(d))")
    assert_rpc "setJob (create stop-only job)" "Compose" "setJob" "$JOB_RUN_PARAMS"
    JOB_RUN_UUID=$(json_uuid "$RPC_OUT")
    if [ -n "$JOB_RUN_UUID" ]; then
        assert_rpc_bg "doJob (stop omvtest_compose)" "Compose" "doJob" "{\"uuid\":\"$JOB_RUN_UUID\"}"
    else
        _skip "doJob (stop omvtest_compose)" "no job uuid"
    fi
else
    _skip "setJob (create stop-only job)" "no file uuid"
    _skip "doJob (stop omvtest_compose)" "no file uuid"
fi
assert_rpc_fails "doJob (bad uuid)" "Compose" "doJob" '{"uuid":"00000000-0000-0000-0000-000000000000"}'

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

assert_rpc "getNetworks has subnet field" "Compose" "getNetworks" \
    '{"start":0,"limit":25,"sortfield":"name","sortdir":"ASC"}' '"subnet"'

assert_rpc "getNetworks has gateway field" "Compose" "getNetworks" \
    '{"start":0,"limit":25,"sortfield":"name","sortdir":"ASC"}' '"gateway"'

assert_rpc "getNetworks has parent field" "Compose" "getNetworks" \
    '{"start":0,"limit":25,"sortfield":"name","sortdir":"ASC"}' '"parent"'

assert_rpc "getNetworks has mode field" "Compose" "getNetworks" \
    '{"start":0,"limit":25,"sortfield":"name","sortdir":"ASC"}' '"mode"'

assert_rpc_bg "getNetworksBg" "Compose" "getNetworksBg" \
    '{"start":0,"limit":25,"sortfield":"name","sortdir":"ASC"}'

assert_rpc "enumerateNetworkList" "Compose" "enumerateNetworkList" '{}'

assert_rpc "getImages" "Compose" "getImages" \
    '{"start":0,"limit":25,"sortfield":"repository","sortdir":"ASC"}' '"total"'

assert_rpc_bg "getImagesBg" "Compose" "getImagesBg" \
    '{"start":0,"limit":25,"sortfield":"repository","sortdir":"ASC"}'

assert_rpc "getContainers" "Compose" "getContainers" '{}'

# ---------------------------------------------------------------------------
# 7b. Networks — create (bridge / IPv6 / macvlan / ipvlan) + connect/disconnect
# ---------------------------------------------------------------------------
section "Networks (create)"

# Build a full setNetwork param object. Defaults match the form-page defaults;
# pass key=value overrides (bool values as the literal true/false).
net_params() {
    python3 - "$@" <<'PY'
import json, sys
d = {
    'name': '', 'driver': 'bridge', 'internal': False,
    'parentnetwork': '', 'macvlanmode': 'bridge', 'ipvlanmode': 'l2',
    'ipv6': False, 'subnet': '', 'gateway': '', 'subnet6': '', 'gateway6': '',
    'iprange': '', 'auxaddress': '',
}
for arg in sys.argv[1:]:
    k, _, v = arg.partition('=')
    d[k] = (v == 'true') if v in ('true', 'false') else v
print(json.dumps(d))
PY
}

# True if a network with the given name appears in getNetworks.
network_exists() {
    omv-rpc -u admin "Compose" "getNetworks" \
        '{"start":0,"limit":1000,"sortfield":"name","sortdir":"ASC"}' 2>/dev/null \
        | python3 -c "
import sys, json
d = json.load(sys.stdin)
rows = d.get('data', d) if isinstance(d, dict) else d
sys.exit(0 if any(r.get('name') == '$1' for r in rows) else 1)
" 2>/dev/null
}

# Assert a field of a named network (from getNetworks) contains a substring.
# The 'containers' field is a list; its string form is searched too.
assert_network_field() {
    local desc=$1 net=$2 field=$3 want=$4 val
    val=$(omv-rpc -u admin "Compose" "getNetworks" \
        '{"start":0,"limit":1000,"sortfield":"name","sortdir":"ASC"}' 2>/dev/null \
        | python3 -c "
import sys, json
d = json.load(sys.stdin)
rows = d.get('data', d) if isinstance(d, dict) else d
for r in rows:
    if r.get('name') == '$net':
        print(r.get('$field', '')); break
" 2>/dev/null)
    if echo "$val" | grep -q "$want"; then
        _pass "$desc"
    else
        _fail "$desc" "network '$net' field '$field'='$val' (wanted '$want')"
    fi
}

# --- Plain IPv4 bridge -------------------------------------------------------
# setNetwork does not raise on a failed docker command, so verify the network
# was actually created via getNetworks rather than trusting the RPC return.
omv-rpc -u admin "Compose" "setNetwork" \
    "$(net_params name=omvtest_net_bridge driver=bridge \
        subnet=172.31.250.0/24 gateway=172.31.250.1)" >/dev/null 2>&1
TEST_NETWORKS+=("omvtest_net_bridge")
if network_exists "omvtest_net_bridge"; then
    _pass "setNetwork (bridge, ipv4)"
    assert_network_field "bridge network reports subnet" omvtest_net_bridge subnet "172.31.250.0/24"
    assert_network_field "bridge network reports gateway" omvtest_net_bridge gateway "172.31.250.1"
else
    _fail "setNetwork (bridge, ipv4)" "omvtest_net_bridge not found in getNetworks"
fi

# --- Dual-stack IPv6 ---------------------------------------------------------
# Requires IPv6 enabled in the daemon; treat a creation failure as a skip.
omv-rpc -u admin "Compose" "setNetwork" \
    "$(net_params name=omvtest_net_v6 driver=bridge ipv6=true \
        subnet=172.31.251.0/24 gateway=172.31.251.1 \
        subnet6=fd00:c0de:beef::/64 gateway6=fd00:c0de:beef::1)" >/dev/null 2>&1
TEST_NETWORKS+=("omvtest_net_v6")
if network_exists "omvtest_net_v6"; then
    _pass "setNetwork (bridge, dual-stack IPv6)"
    assert_network_field "dual-stack network reports IPv6 subnet" \
        omvtest_net_v6 subnet "fd00:c0de:beef"
else
    _skip "setNetwork (bridge, dual-stack IPv6)" "daemon IPv6 likely disabled"
    _skip "dual-stack network reports IPv6 subnet" "network not created"
fi

# --- macvlan / ipvlan with parent + mode -------------------------------------
# Use throwaway dummy interfaces as parents so the host's real NICs are never
# touched. A parent can be either macvlan OR ipvlan, so use one dummy per test.
section "Networks (macvlan / ipvlan parent + mode)"

if ip link add omvtest_mv0 type dummy 2>/dev/null; then
    TEST_DUMMY_IFACES+=("omvtest_mv0")
    ip link set omvtest_mv0 up 2>/dev/null || true
    mv_out=$(omv-rpc -u admin "Compose" "setNetwork" \
        "$(net_params name=omvtest_net_macvlan driver=macvlan \
            parentnetwork=omvtest_mv0 macvlanmode=bridge \
            subnet=172.31.252.0/24 gateway=172.31.252.1)" 2>&1)
    TEST_NETWORKS+=("omvtest_net_macvlan")
    if network_exists "omvtest_net_macvlan"; then
        _pass "setNetwork (macvlan with parent)"
        assert_network_field "macvlan parent recorded" omvtest_net_macvlan parent omvtest_mv0
        assert_network_field "macvlan mode recorded" omvtest_net_macvlan mode bridge
    else
        _fail "setNetwork (macvlan with parent)" \
            "not created: $(echo "$mv_out" | tr '\n' ' ' | tail -c 300)"
    fi
else
    _skip "setNetwork (macvlan with parent)" "could not create dummy interface"
    _skip "macvlan parent recorded" "no dummy interface"
    _skip "macvlan mode recorded" "no dummy interface"
fi

# ipvlan parent handling is the regression test for the bug where the parent
# opt was only emitted for macvlan.
if ip link add omvtest_iv0 type dummy 2>/dev/null; then
    TEST_DUMMY_IFACES+=("omvtest_iv0")
    ip link set omvtest_iv0 up 2>/dev/null || true
    iv_out=$(omv-rpc -u admin "Compose" "setNetwork" \
        "$(net_params name=omvtest_net_ipvlan driver=ipvlan \
            parentnetwork=omvtest_iv0 ipvlanmode=l2 \
            subnet=172.31.253.0/24 gateway=172.31.253.1)" 2>&1)
    TEST_NETWORKS+=("omvtest_net_ipvlan")
    if network_exists "omvtest_net_ipvlan"; then
        _pass "setNetwork (ipvlan with parent)"
        assert_network_field "ipvlan parent recorded" omvtest_net_ipvlan parent omvtest_iv0
        assert_network_field "ipvlan mode recorded" omvtest_net_ipvlan mode l2
    else
        _fail "setNetwork (ipvlan with parent)" \
            "not created: $(echo "$iv_out" | tr '\n' ' ' | tail -c 300)"
    fi
else
    _skip "setNetwork (ipvlan with parent)" "could not create dummy interface"
    _skip "ipvlan parent recorded" "no dummy interface"
    _skip "ipvlan mode recorded" "no dummy interface"
fi

# --- Connect / disconnect a container ---------------------------------------
section "Networks (connect / disconnect)"

# Failure path: setNetwork/doNetworkConnect swallow the docker exit code, so
# assert the daemon's error text is surfaced in the returned output.
conn_err=$(omv-rpc -u admin "Compose" "doNetworkConnect" \
    '{"name":"bridge","container":"omvtest_no_such_ctr","command":"connect","ipaddress":""}' 2>&1)
if echo "$conn_err" | grep -qiE "no such container|not found|error"; then
    _pass "doNetworkConnect surfaces error for missing container"
else
    _fail "doNetworkConnect surfaces error for missing container" "output: ${conn_err:0:200}"
fi

# Happy path: needs a long-running throwaway container. Only attempt it when a
# shell-capable image (alpine/busybox) is already present locally.
NET_IMG=""
if command -v "$RUNTIME" >/dev/null 2>&1; then
    for cand in $("$RUNTIME" image ls --format '{{.Repository}}:{{.Tag}}' 2>/dev/null); do
        case "$cand" in
            *alpine*|*busybox*) NET_IMG="$cand"; break ;;
        esac
    done
fi

if [ -n "$NET_IMG" ] && network_exists "omvtest_net_bridge" \
    && "$RUNTIME" run -d --name omvtest_net_ctr "$NET_IMG" sleep 600 >/dev/null 2>&1; then
    NET_TEST_CTR="omvtest_net_ctr"
    omv-rpc -u admin "Compose" "doNetworkConnect" \
        '{"name":"omvtest_net_bridge","container":"omvtest_net_ctr","command":"connect","ipaddress":"172.31.250.50"}' \
        >/dev/null 2>&1
    assert_network_field "doNetworkConnect attaches container to network" \
        omvtest_net_bridge containers omvtest_net_ctr

    omv-rpc -u admin "Compose" "doNetworkConnect" \
        '{"name":"omvtest_net_bridge","container":"omvtest_net_ctr","command":"disconnect"}' \
        >/dev/null 2>&1
    val=$(omv-rpc -u admin "Compose" "getNetworks" \
        '{"start":0,"limit":1000,"sortfield":"name","sortdir":"ASC"}' 2>/dev/null \
        | python3 -c "
import sys, json
d = json.load(sys.stdin)
rows = d.get('data', d) if isinstance(d, dict) else d
for r in rows:
    if r.get('name') == 'omvtest_net_bridge':
        print(r.get('containers', '')); break
" 2>/dev/null)
    if echo "$val" | grep -q "omvtest_net_ctr"; then
        _fail "doNetworkConnect disconnect detaches container" "still attached: $val"
    else
        _pass "doNetworkConnect disconnect detaches container"
    fi
else
    _skip "doNetworkConnect attaches container to network" \
        "no local alpine/busybox image or bridge network unavailable"
    _skip "doNetworkConnect disconnect detaches container" "happy path skipped"
fi

# --- doDockerNetworkCmd ------------------------------------------------------
section "Networks (commands)"

if network_exists "omvtest_net_bridge"; then
    assert_rpc_bg "doDockerNetworkCmd inspect" "Compose" "doDockerNetworkCmd" \
        '{"command":"inspect","name":"omvtest_net_bridge"}' "172.31.250.0/24"
else
    _skip "doDockerNetworkCmd inspect" "omvtest_net_bridge not created"
fi

omv-rpc -u admin "Compose" "setNetwork" \
    "$(net_params name=omvtest_net_rm driver=bridge)" >/dev/null 2>&1
TEST_NETWORKS+=("omvtest_net_rm")
if network_exists "omvtest_net_rm"; then
    assert_rpc_bg "doDockerNetworkCmd rm" "Compose" "doDockerNetworkCmd" \
        '{"command":"rm","name":"omvtest_net_rm"}'
    if network_exists "omvtest_net_rm"; then
        _fail "doDockerNetworkCmd rm removed the network" "omvtest_net_rm still listed"
    else
        _pass "doDockerNetworkCmd rm removed the network"
    fi
else
    _skip "doDockerNetworkCmd rm" "omvtest_net_rm not created"
    _skip "doDockerNetworkCmd rm removed the network" "omvtest_net_rm not created"
fi

assert_rpc_bg_fails "doDockerNetworkCmd (missing network) fails" "Compose" "doDockerNetworkCmd" \
    '{"command":"inspect","name":"omvtest_no_such_net"}'

# ---------------------------------------------------------------------------
# 7c. Volumes — create (plain / labels / driver opts / NFS mount type)
# ---------------------------------------------------------------------------
section "Volumes (create)"

# Build a full setVolume param object. Defaults match the form-page defaults;
# pass key=value overrides (bool values as the literal true/false).
vol_params() {
    python3 - "$@" <<'PY'
import json, sys
d = {
    'name': '', 'driver': 'local', 'advanced': False,
    'mounttype': 'none', 'device': '', 'mountoptions': '',
    'driveropts': '', 'labels': '',
}
for arg in sys.argv[1:]:
    k, _, v = arg.partition('=')
    d[k] = (v == 'true') if v in ('true', 'false') else v
print(json.dumps(d))
PY
}

# True if a volume with the given name appears in getVolumes.
volume_exists() {
    omv-rpc -u admin "Compose" "getVolumes" \
        '{"start":0,"limit":1000,"sortfield":"name","sortdir":"ASC"}' 2>/dev/null \
        | python3 -c "
import sys, json
d = json.load(sys.stdin)
rows = d.get('data', d) if isinstance(d, dict) else d
sys.exit(0 if any(r.get('name') == '$1' for r in rows) else 1)
" 2>/dev/null
}

# Assert that 'docker/podman volume inspect <name>' output contains a substring.
# getVolumes does not expose driver options/labels, so inspect the runtime.
assert_volume_inspect() {
    local desc=$1 vol=$2 want=$3 out
    out=$("$RUNTIME" volume inspect "$vol" 2>/dev/null)
    if echo "$out" | grep -q "$want"; then
        _pass "$desc"
    else
        _fail "$desc" "volume '$vol' inspect missing '$want'"
    fi
}

# --- Plain local volume ------------------------------------------------------
# setVolume swallows the docker exit code, so verify via getVolumes rather than
# trusting the RPC return.
omv-rpc -u admin "Compose" "setVolume" \
    "$(vol_params name=omvtest_vol_plain driver=local)" >/dev/null 2>&1
TEST_VOLUMES+=("omvtest_vol_plain")
if volume_exists "omvtest_vol_plain"; then
    _pass "setVolume (plain local)"
else
    _fail "setVolume (plain local)" "omvtest_vol_plain not found in getVolumes"
fi

# --- Labels ------------------------------------------------------------------
# Labels are accepted by the local driver on every setup, so this must always
# create. (Kept separate from driver-opts: a rejected opt must not mask the
# label assertion.)
omv-rpc -u admin "Compose" "setVolume" \
    "$(vol_params name=omvtest_vol_labels driver=local advanced=true \
        labels=com.omvtest.usage=ci)" >/dev/null 2>&1
TEST_VOLUMES+=("omvtest_vol_labels")
if volume_exists "omvtest_vol_labels"; then
    _pass "setVolume (labels)"
    assert_volume_inspect "volume reports label" omvtest_vol_labels "com.omvtest.usage"
else
    _fail "setVolume (labels)" "omvtest_vol_labels not found in getVolumes"
    _skip "volume reports label" "volume not created"
fi

# --- Extra driver options ----------------------------------------------------
# Exercise driveropts pass-through with a portable tmpfs mount: a bare
# '--opt size=' is rejected by the local driver (needs quota-capable backing),
# but 'type=tmpfs,device=tmpfs,o=size=' is accepted everywhere on Linux.
omv-rpc -u admin "Compose" "setVolume" \
    "$(vol_params name=omvtest_vol_opts driver=local advanced=true \
        driveropts=type=tmpfs,device=tmpfs,o=size=10m)" >/dev/null 2>&1
TEST_VOLUMES+=("omvtest_vol_opts")
if volume_exists "omvtest_vol_opts"; then
    _pass "setVolume (driver opts)"
    assert_volume_inspect "volume records driver opt" omvtest_vol_opts '"type": "tmpfs"'
else
    _fail "setVolume (driver opts)" "omvtest_vol_opts not found in getVolumes"
    _skip "volume records driver opt" "volume not created"
fi

# --- NFS mount type ----------------------------------------------------------
# 'docker volume create' only records the mount options; the share is mounted
# lazily on first use, so creation succeeds even with an unreachable address.
omv-rpc -u admin "Compose" "setVolume" \
    "$(vol_params name=omvtest_vol_nfs driver=local advanced=true \
        mounttype=nfs device=:/export/omvtest mountoptions=addr=127.0.0.1,rw)" \
    >/dev/null 2>&1
TEST_VOLUMES+=("omvtest_vol_nfs")
if volume_exists "omvtest_vol_nfs"; then
    _pass "setVolume (NFS mount type)"
    assert_volume_inspect "NFS volume records type=nfs" omvtest_vol_nfs '"type": "nfs"'
    assert_volume_inspect "NFS volume records device" omvtest_vol_nfs "/export/omvtest"
else
    _fail "setVolume (NFS mount type)" "omvtest_vol_nfs not found in getVolumes"
fi

# --- getVolumes maps volumes to the containers using them --------------------
# Print the 'containers' field of a named volume from getVolumes.
volume_containers() {
    omv-rpc -u admin "Compose" "getVolumes" \
        '{"start":0,"limit":1000,"sortfield":"name","sortdir":"ASC"}' 2>/dev/null \
        | python3 -c "
import sys, json
d = json.load(sys.stdin)
rows = d.get('data', d) if isinstance(d, dict) else d
for r in rows:
    if r.get('name') == '$1':
        print(r.get('containers', '')); break
" 2>/dev/null
}

# Start a throwaway container that mounts omvtest_vol_plain, then verify
# getVolumes reports that container against the volume (and that an unused
# volume stays empty). Needs a local shell-capable image (reuses NET_IMG).
if [ -n "$NET_IMG" ] && volume_exists "omvtest_vol_plain" \
    && "$RUNTIME" run -d --name omvtest_vol_ctr -v omvtest_vol_plain:/data \
        "$NET_IMG" sleep 600 >/dev/null 2>&1; then
    VOL_TEST_CTR="omvtest_vol_ctr"
    val=$(volume_containers "omvtest_vol_plain")
    if echo "$val" | grep -q "omvtest_vol_ctr"; then
        _pass "getVolumes lists container using the volume"
    else
        _fail "getVolumes lists container using the volume" "containers='$val'"
    fi
    # A volume with no container attached must report an empty list.
    if [ -z "$(volume_containers "omvtest_vol_nfs")" ]; then
        _pass "getVolumes reports empty containers for an unused volume"
    else
        _fail "getVolumes reports empty containers for an unused volume" \
            "omvtest_vol_nfs unexpectedly has containers"
    fi
else
    _skip "getVolumes lists container using the volume" \
        "no local alpine/busybox image or volume unavailable"
    _skip "getVolumes reports empty containers for an unused volume" "happy path skipped"
fi

# --- doDockerVolumeCmd -------------------------------------------------------
section "Volumes (commands)"

if volume_exists "omvtest_vol_labels"; then
    assert_rpc_bg "doDockerVolumeCmd inspect" "Compose" "doDockerVolumeCmd" \
        '{"command":"inspect","name":"omvtest_vol_labels"}' "com.omvtest.usage"
else
    _skip "doDockerVolumeCmd inspect" "omvtest_vol_labels not created"
fi
if volume_exists "omvtest_vol_opts"; then
    assert_rpc_bg "doDockerVolumeCmd rm" "Compose" "doDockerVolumeCmd" \
        '{"command":"rm","name":"omvtest_vol_opts"}'
    if volume_exists "omvtest_vol_opts"; then
        _fail "doDockerVolumeCmd rm removed the volume" "omvtest_vol_opts still listed"
    else
        _pass "doDockerVolumeCmd rm removed the volume"
    fi
else
    _skip "doDockerVolumeCmd rm" "omvtest_vol_opts not created"
    _skip "doDockerVolumeCmd rm removed the volume" "omvtest_vol_opts not created"
fi
assert_rpc_bg_fails "doDockerVolumeCmd (missing volume) fails" "Compose" "doDockerVolumeCmd" \
    '{"command":"inspect","name":"omvtest_no_such_vol"}'

# ---------------------------------------------------------------------------
# 7e. Containers — commands, logs, terminal links, autocompose
# ---------------------------------------------------------------------------
section "Containers"

assert_rpc "getContainersTerm" "Compose" "getContainersTerm" '{}'

# Regression: getContainersTerm (allowed for every role) handed non-admin
# users terminal links signed for the cterm autouser.
TERM_OUT=$(omv-rpc -u "$NONADMIN_USER" "Compose" "getContainersTerm" '{}' 2>&1)
TERM_USERS=$(echo "$TERM_OUT" | python3 -c "
import sys, json, re
rows = json.load(sys.stdin)
print(' '.join(sorted({u for r in rows for u in re.findall(r'user=([^&\"]+)', r.get('term', ''))})))
" 2>/dev/null)
if [ -z "$TERM_USERS" ]; then
    _skip "getContainersTerm signs non-admin links for the caller" "cterm not enabled or no running containers"
elif [ "$TERM_USERS" = "$NONADMIN_USER" ]; then
    _pass "getContainersTerm signs non-admin links for the caller"
else
    _fail "getContainersTerm signs non-admin links for the caller" "links signed for: $TERM_USERS"
fi

assert_rpc_fails "doDockerCmd rejects unknown cmd" "Compose" "doDockerCmd" \
    '{"id":"omvtest_no_such_ctr","cmd":"rm"}'
assert_rpc_bg_fails "doContainerCommand (missing container) fails" "Compose" "doContainerCommand" \
    '{"command":"restart","command2":"","id":"omvtest_no_such_ctr"}'

if [ -n "$NET_TEST_CTR" ]; then
    assert_rpc_bg "doDockerCmd inspect" "Compose" "doDockerCmd" \
        "{\"id\":\"$NET_TEST_CTR\",\"cmd\":\"inspect\"}" "$NET_TEST_CTR"
    assert_rpc_bg "doContainerCommand restart" "Compose" "doContainerCommand" \
        "{\"command\":\"restart\",\"command2\":\"\",\"id\":\"$NET_TEST_CTR\"}"
    if [ "$("$RUNTIME" inspect -f '{{.State.Running}}' "$NET_TEST_CTR" 2>/dev/null)" = "true" ]; then
        _pass "doContainerCommand restart left the container running"
    else
        _fail "doContainerCommand restart left the container running" "container not running"
    fi
    assert_download "getContainerLog" "Compose" "getContainerLog" \
        "{\"id\":\"$NET_TEST_CTR\",\"name\":\"omvtest\"}" "omvtest_$NET_TEST_CTR.log"

    # The container's image must be reported as in use. The container was
    # started after getImages last ran, so drop the cached container list.
    omv-rpc -u admin "Compose" "clearCacheFiles" '{}' >/dev/null 2>&1
    inuse=$(omv-rpc -u admin "Compose" "getImages" \
        '{"start":0,"limit":1000,"sortfield":"repo","sortdir":"ASC"}' 2>/dev/null \
        | python3 -c "
import sys, json
for r in json.load(sys.stdin)['data']:
    if '%s:%s' % (r['repo'], r['tag']) == '$NET_IMG':
        print(r['inuse']); break" 2>/dev/null)
    if [ "$inuse" = "True" ]; then
        _pass "getImages marks the container's image in use"
    else
        _fail "getImages marks the container's image in use" \
            "inuse='$inuse' for $NET_IMG (container image: $("$RUNTIME" inspect -f '{{.Image}}' "$NET_TEST_CTR" 2>/dev/null), image id: $("$RUNTIME" image inspect -f '{{.Id}}' "$NET_IMG" 2>/dev/null))"
    fi

    if [ -f /usr/bin/autocompose.py ]; then
        AC_PARAMS="{\"container\":\"$NET_TEST_CTR\",\"name\":\"omvtest_autocompose\",\"description\":\"RPC test\",\"version\":\"3\"}"
        assert_rpc "doAutocompose" "Compose" "doAutocompose" "$AC_PARAMS"
        ac_uuid=$(json_uuid "$RPC_OUT")
        [ -z "$ac_uuid" ] && ac_uuid=$(recover_uuid_from_list "Compose" "getFileList" "name" "omvtest_autocompose")
        if [ -n "$ac_uuid" ]; then
            EXTRA_FILE_UUIDS+=("$ac_uuid")
            # Match the bare image name: the JSON output escapes slashes.
            ac_img="${NET_IMG%:*}"
            assert_rpc "doAutocompose body describes the container" "Compose" "getFile" \
                "{\"uuid\":\"$ac_uuid\"}" "${ac_img##*/}"
        else
            _skip "doAutocompose body describes the container" "no file uuid"
        fi
        assert_rpc_fails "doAutocompose (duplicate name)" "Compose" "doAutocompose" "$AC_PARAMS"
    else
        _skip "doAutocompose" "/usr/bin/autocompose.py not installed"
    fi
else
    for t in "doDockerCmd inspect" "doContainerCommand restart" "getContainerLog" \
        "getImages marks the container's image in use" "doAutocompose"; do
        _skip "$t" "no test container (needs a local alpine/busybox image)"
    done
fi

# ---------------------------------------------------------------------------
# 7d. Bind mount paths — createBindPath (host dir prep, not a docker volume)
# ---------------------------------------------------------------------------
section "Bind mount paths (create)"

# Pre-clean any leftover from a previous run so ownership/mode assertions are
# against a freshly created tree.
rm -rf "$BIND_TEST_DIR" 2>/dev/null || true

# --- Happy path: absolute path with owner/group/mode -------------------------
assert_rpc "createBindPath (absolute + owner/perms)" "Compose" "createBindPath" \
    "{\"source\":\"absolute\",\"abspath\":\"$BIND_TEST_DIR/config\",\"owner\":\"root\",\"group\":\"root\",\"mode\":\"755\",\"recursive\":false}" \
    '"path"'
if [ -d "$BIND_TEST_DIR/config" ]; then
    _pass "createBindPath created the directory"
    perms=$(stat -c '%a' "$BIND_TEST_DIR/config" 2>/dev/null)
    if [ "$perms" = "755" ]; then
        _pass "createBindPath applied mode 755"
    else
        _fail "createBindPath applied mode 755" "mode is '$perms'"
    fi
else
    _fail "createBindPath created the directory" "$BIND_TEST_DIR/config missing"
    _skip "createBindPath applied mode 755" "directory not created"
fi

# --- Nested path is created with parents -------------------------------------
assert_rpc "createBindPath (nested, mode only)" "Compose" "createBindPath" \
    "{\"source\":\"absolute\",\"abspath\":\"$BIND_TEST_DIR/a/b/c\",\"mode\":\"750\"}" \
    '"path"'
if [ -d "$BIND_TEST_DIR/a/b/c" ]; then
    _pass "createBindPath created nested parents"
else
    _fail "createBindPath created nested parents" "$BIND_TEST_DIR/a/b/c missing"
fi

# --- Rejection: protected system path ----------------------------------------
assert_rpc_fails "createBindPath rejects protected path (/etc)" "Compose" \
    "createBindPath" '{"source":"absolute","abspath":"/etc/omvtest_should_not_exist"}'
if [ ! -e "/etc/omvtest_should_not_exist" ]; then
    _pass "createBindPath did not touch /etc"
else
    rm -rf "/etc/omvtest_should_not_exist" 2>/dev/null || true
    _fail "createBindPath did not touch /etc" "directory was created under /etc"
fi

# --- Rejection: path traversal -----------------------------------------------
assert_rpc_fails "createBindPath rejects '..' traversal" "Compose" \
    "createBindPath" "{\"source\":\"absolute\",\"abspath\":\"$BIND_TEST_DIR/../../etc/x\"}"

# --- Rejection: non-absolute path --------------------------------------------
assert_rpc_fails "createBindPath rejects relative path" "Compose" \
    "createBindPath" '{"source":"absolute","abspath":"relative/path"}'

# --- Rejection: invalid (non-octal) mode -------------------------------------
assert_rpc_fails "createBindPath rejects bad mode" "Compose" \
    "createBindPath" "{\"source\":\"absolute\",\"abspath\":\"$BIND_TEST_DIR/badmode\",\"mode\":\"999\"}"

# --- Rejection: shared folder source with no folder selected -----------------
assert_rpc_fails "createBindPath rejects missing shared folder" "Compose" \
    "createBindPath" '{"source":"sharedfolder","relpath":"foo"}'

# ---------------------------------------------------------------------------
# 8. Stats
# ---------------------------------------------------------------------------
section "Stats"

assert_rpc "getStats" "Compose" "getStats" '{}'
assert_rpc_bg "getStatsBg" "Compose" "getStatsBg" '{}'

# Regression: an empty stats cache (no running containers) produced a blank row.
STATS_CACHE=/var/cache/openmediavault/compose_cache_stats.json
if [ "$(json_get "$SETTINGS" "cachetimestats")" -gt 0 ] 2>/dev/null; then
    : > "$STATS_CACHE"
    assert_rpc "getStats with empty cache returns no rows" "Compose" "getStats" \
        '{"start":0,"limit":25,"sortfield":"name","sortdir":"ASC"}' '"total": *0'
    rm -f "$STATS_CACHE"
else
    _skip "getStats with empty cache returns no rows" "stats cache disabled (cachetimestats=0)"
fi

# convertToBytes is private; call it through reflection on the installed class.
RPC_INC=/usr/share/openmediavault/engined/rpc/compose.inc
CONV_OUT=$(php -r '
require_once "/usr/share/php/openmediavault/autoloader.inc";
require_once "/usr/share/php/openmediavault/globals.inc";
require_once $argv[1];
$m = new ReflectionMethod("OMVRpcServiceCompose", "convertToBytes");
$m->setAccessible(true);
$o = (new ReflectionClass("OMVRpcServiceCompose"))->newInstanceWithoutConstructor();
foreach (array_slice($argv, 2) as $v) echo $v, "=", $m->invoke($o, $v), "\n";
' "$RPC_INC" 12B 2kB 1.5KiB 1.5MiB 1GB 2GiB 2>&1)
for pair in 12B=12 2kB=2048 1.5KiB=1536 1.5MiB=1572864 1GB=1073741824 2GiB=2147483648; do
    if echo "$CONV_OUT" | grep -qx "$pair"; then
        _pass "convertToBytes $pair"
    else
        _fail "convertToBytes $pair" "$(echo "$CONV_OUT" | grep "^${pair%%=*}=" || echo "${CONV_OUT:0:200}")"
    fi
done

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
    '{"start":0,"limit":25,"sortfield":"repo","sortdir":"ASC"}' '"total"'

# Logging in to a registry nobody listens on fails without network access,
# and the failure is reported; the repo must not be added.
# The password contains a single quote, which used to break the command.
REPO_PASSWD="omvtest_s3cr3t'pw"
REPO_OUT=$(omv-rpc -u admin "Compose" "repoLogin" \
    "{\"url\":\"127.0.0.1:1\",\"username\":\"omvtest\",\"passwd\":\"$REPO_PASSWD\"}" 2>&1)
if echo "$REPO_OUT" | grep -q "docker login"; then
    _pass "repoLogin (unreachable registry) fails"
else
    _fail "repoLogin (unreachable registry) fails" "${REPO_OUT:0:300}"
fi
# Regression: the password was passed with echo on the command line, so it
# showed up in the error message, the engined log and the process list.
if echo "$REPO_OUT" | grep -qF "omvtest_s3cr3t"; then
    _fail "repoLogin error does not contain the password" "password found in: ${REPO_OUT:0:300}"
else
    _pass "repoLogin error does not contain the password"
fi
if echo "$REPO_OUT" | grep -q "unexpected EOF\|Syntax error"; then
    _fail "repoLogin handles a quote in the password" "${REPO_OUT:0:300}"
else
    _pass "repoLogin handles a quote in the password"
fi
if list_field "getRepoList" "repo" "127.0.0.1:1" "repo" \
    '{"start":0,"limit":1000,"sortfield":"repo","sortdir":"ASC"}' | grep -q .; then
    _fail "repoLogin (unreachable registry) adds no repo" "127.0.0.1:1 listed"
else
    _pass "repoLogin (unreachable registry) adds no repo"
fi
assert_rpc "repoLogout" "Compose" "repoLogout" '{"repo":"127.0.0.1:1"}'

BACKUP_PATH=""
BACKUP_SF_UUID=$(json_get "$SETTINGS" "backupsharedfolderref")
if [ -n "$BACKUP_SF_UUID" ] && [ "$BACKUP_SF_UUID" != "null" ]; then
    BACKUP_PATH=$(get_sf_path "$BACKUP_SF_UUID")
fi

assert_rpc_fails "deleteBackup (no name)" "Compose" "deleteBackup" '{"name":""}'
if [ -z "$BACKUP_PATH" ]; then
    assert_rpc_fails "deleteBackup (no backup folder) fails" "Compose" "deleteBackup" \
        '{"name":"omvtest_no_such_backup"}' "shared folder for backups"
    _skip "deleteBackup (missing backup)" "backup shared folder not configured"
    _skip "deleteBackup rejects '..' traversal" "backup shared folder not configured"
    _skip "deleteBackup traversal left the target alone" "backup shared folder not configured"
else
    assert_rpc_fails "deleteBackup (missing backup)" "Compose" "deleteBackup" \
        '{"name":"omvtest_no_such_backup"}' "Directory does not exist"
    # Regression: a name with '../' deleted directories outside the backup
    # folder. Point it at a throwaway directory next to the backup folder.
    BACKUP_TRAVERSAL_DIR="$(dirname "$BACKUP_PATH")/omvtest_traversal_target"
    mkdir -p "$BACKUP_TRAVERSAL_DIR"
    assert_rpc_fails "deleteBackup rejects '..' traversal" "Compose" "deleteBackup" \
        '{"name":"../omvtest_traversal_target"}' "Invalid backup name"
    sleep 2
    if [ -d "$BACKUP_TRAVERSAL_DIR" ]; then
        _pass "deleteBackup traversal left the target alone"
    else
        _fail "deleteBackup traversal left the target alone" "$BACKUP_TRAVERSAL_DIR was deleted"
    fi
fi

# omv-compose-restore exits non-zero when no compose name is given.
assert_rpc_bg_fails "doRestore (no name) fails" "Compose" "doRestore" '{"backup":"","time":""}'

# restoreGlobalEnv overwrites the global env from the backup folder; the
# original is restored right after.
if [ -n "$BACKUP_PATH" ] && [ -f "$BACKUP_PATH/global.env" ]; then
    assert_rpc "restoreGlobalEnv" "Compose" "restoreGlobalEnv" '{}'
    want=$(python3 -c "import sys; print(open(sys.argv[1]).read().strip())" "$BACKUP_PATH/global.env")
    got=$(omv-rpc -u admin "Compose" "getGlobalEnv" '{}' 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['globalenv'])" 2>/dev/null)
    if [ "$got" = "$want" ]; then
        _pass "restoreGlobalEnv loaded the backup global.env"
    else
        _fail "restoreGlobalEnv loaded the backup global.env" "global env differs from backup"
    fi
    [ -n "${RESTORE_GENV:-}" ] && omv-rpc -u admin "Compose" "setGlobalEnv" "$RESTORE_GENV" >/dev/null 2>&1
else
    assert_rpc_fails "restoreGlobalEnv (no backup global.env) fails" "Compose" "restoreGlobalEnv" '{}'
    _skip "restoreGlobalEnv loaded the backup global.env" "no global.env in backup folder"
fi

# ---------------------------------------------------------------------------
# 11. Compose file — doCommand (config only, non-destructive)
# ---------------------------------------------------------------------------
section "Compose file commands"

if [ -n "$FILE_UUID" ]; then
    assert_rpc_bg "doCommand (config)" "Compose" "doCommand" \
        "{\"uuid\":\"$FILE_UUID\",\"command\":\"config\",\"command2\":\"\"}"
    # doCommand runs compose through omv-compose-run, which logs each command
    CMD_LOG_LINE=$(tail -n 1 /var/log/omv-compose-run.log 2>/dev/null || true)
    if echo "$CMD_LOG_LINE" | grep -q "\[composerun\] .*/omvtest_compose/omvtest_compose.yml .* config$"; then
        _pass "doCommand runs through omv-compose-run"
    else
        _fail "doCommand runs through omv-compose-run" "last log line: ${CMD_LOG_LINE:0:300}"
    fi
else
    _skip "doCommand (config)" "no file uuid"
    _skip "doCommand runs through omv-compose-run" "no file uuid"
fi

# Service RPCs take the compose file path from the UI; it must be inside the
# compose shared folder.
assert_rpc_fails "doServiceCommand rejects path outside compose folder" "Compose" "doServiceCommand" \
    '{"command":"ps","command2":"","service":"x","path":"/etc/omvtest/omvtest.yml","envpath":"","overridepath":""}'
assert_rpc_fails "getServiceLog rejects path outside compose folder" "Compose" "getServiceLog" \
    '{"service":"x","name":"x","path":"/etc/omvtest/omvtest.yml","envpath":""}'

assert_rpc_bg_fails "doCommandList (bad uuid) fails" "Compose" "doCommandList" \
    '{"uuids":"00000000-0000-0000-0000-000000000000","command":"config","command2":""}'

if [ -n "$FILE_UUID" ]; then
    TEST_YML="$SF_PATH/omvtest_compose/omvtest_compose.yml"
    assert_rpc_bg "doCommandList (config)" "Compose" "doCommandList" \
        "{\"uuids\":\"$FILE_UUID\",\"command\":\"config\",\"command2\":\"\"}" "hello"
    assert_rpc_bg "doServiceCommand (config, valid path)" "Compose" "doServiceCommand" \
        "{\"command\":\"config\",\"command2\":\"\",\"service\":\"hello\",\"path\":\"$TEST_YML\",\"envpath\":\"\",\"overridepath\":\"\"}" \
        "hello"
    assert_download "getLog" "Compose" "getLog" '{"name":"omvtest_compose"}' "omvtest_compose.log"
    assert_download "getServiceLog" "Compose" "getServiceLog" \
        "{\"service\":\"hello\",\"name\":\"omvtest\",\"path\":\"$TEST_YML\",\"envpath\":\"\"}" \
        "hello_omvtest.log"
    # git log of a file / global.env. Without a repo the task appends an
    # error marker instead of throwing, so both cases must complete.
    assert_rpc_bg "doGit (diff)" "Compose" "doGit" "{\"uuid\":\"$FILE_UUID\",\"command\":\"diff\"}"
else
    for t in "doCommandList (config)" "doServiceCommand (config, valid path)" "getLog" \
        "getServiceLog" "doGit (diff)"; do
        _skip "$t" "no file uuid"
    done
fi
assert_rpc_bg "doGit (diffg)" "Compose" "doGit" '{"uuid":"","command":"diffg"}'

# Only the validation is tested here; a real prune is opt-in (see below).
assert_rpc_fails "doPrune rejects unknown command" "Compose" "doPrune" '{"command":"system prune --all --volumes"}'

# ---------------------------------------------------------------------------
# 11b. omv-compose-run wrapper
# ---------------------------------------------------------------------------
section "omv-compose-run"

# Use OMV_COMPOSE_RUN if set, else the installed command, else the repo copy
# (so the wrapper can be tested before the package is installed).
RUN_CMD="${OMV_COMPOSE_RUN:-$(command -v omv-compose-run 2>/dev/null || true)}"
if [ -z "$RUN_CMD" ] && [ -x "$(dirname "$0")/../usr/sbin/omv-compose-run" ]; then
    RUN_CMD="$(dirname "$0")/../usr/sbin/omv-compose-run"
fi

# Run omv-compose-run and check its exit code. Output is in $RUN_OUT.
# Usage: assert_run <desc> <expected exit code> [pattern] -- <args...>
RUN_OUT=""
assert_run() {
    local desc=$1 want=$2 pattern="" ec=0
    shift 2
    if [ "${1:-}" != "--" ]; then pattern=$1; shift; fi
    shift
    RUN_OUT=$("$RUN_CMD" "$@" 2>&1) || ec=$?
    if [ $ec -ne "$want" ]; then
        _fail "$desc" "exit $ec (expected $want): ${RUN_OUT:0:300}"
        return 1
    fi
    if [ -n "$pattern" ] && ! echo "$RUN_OUT" | grep -qF -- "$pattern"; then
        _fail "$desc" "'$pattern' not found in: ${RUN_OUT:0:300}"
        return 1
    fi
    _pass "$desc"
    return 0
}

if [ -z "$RUN_CMD" ]; then
    _skip "omv-compose-run tests" "omv-compose-run not found"
else
    info "Using $RUN_CMD"

    # Argument handling (no stack needed)
    assert_run "omv-compose-run --help" 0 "Usage:" -- --help
    assert_run "omv-compose-run (no name) exits 10" 10 -- ""
    assert_run "omv-compose-run rejects name with slash" 10 "Invalid compose name" -- 'a/b' ps
    assert_run "omv-compose-run rejects path traversal" 10 "Invalid compose name" -- '..' ps
    assert_run "omv-compose-run rejects name starting with -" 10 "Invalid compose name" -- -x ps
    assert_run "omv-compose-run missing stack exits 13" 13 "does not exist" -- omvtest_nonexistent ps

    RUN_SF_UUID=$(json_get "$SETTINGS" "sharedfolderref")
    RUN_SF_PATH=$(omv-rpc -u admin "ShareMgmt" "getPath" "{\"uuid\":\"$RUN_SF_UUID\"}" 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin).rstrip('/'))" 2>/dev/null || echo "")
    RUN_DIR="$RUN_SF_PATH/omvtest_compose"

    if [ -z "$FILE_UUID" ] || [ ! -f "$RUN_DIR/omvtest_compose.yml" ]; then
        _skip "omv-compose-run stack tests" "no omvtest_compose file on disk"
    else
        # Dry run: check the arguments the wrapper builds
        assert_run "dry-run adds --file for stack yml" 0 \
            "--file $RUN_DIR/omvtest_compose.yml" -- -n omvtest_compose config
        DRY_OUT="$RUN_OUT"
        if echo "$DRY_OUT" | grep -qF -- "--env-file $RUN_DIR/omvtest_compose.env"; then
            _pass "dry-run adds --env-file for stack env"
        else
            _fail "dry-run adds --env-file for stack env" "${DRY_OUT:0:300}"
        fi
        if [ -f "$RUN_SF_PATH/global.env" ]; then
            if echo "$DRY_OUT" | grep -qF -- "--env-file $RUN_SF_PATH/global.env --env-file $RUN_DIR/omvtest_compose.env"; then
                _pass "dry-run adds global.env before stack env"
            else
                _fail "dry-run adds global.env before stack env" "${DRY_OUT:0:300}"
            fi
        elif echo "$DRY_OUT" | grep -qF "global.env"; then
            _fail "dry-run omits missing global.env" "${DRY_OUT:0:300}"
        else
            _pass "dry-run omits missing global.env"
        fi
        # The plugin normally writes compose.override.yml even when the
        # override is empty, so check both cases against what is on disk.
        if [ -f "$RUN_DIR/compose.override.yml" ]; then
            if echo "$DRY_OUT" | grep -qF -- "--file $RUN_DIR/compose.override.yml"; then
                _pass "dry-run adds existing override"
            else
                _fail "dry-run adds existing override" "${DRY_OUT:0:300}"
            fi
        else
            if echo "$DRY_OUT" | grep -qF "compose.override.yml"; then
                _fail "dry-run omits missing override" "${DRY_OUT:0:300}"
            else
                _pass "dry-run omits missing override"
            fi
        fi
        if [ "$RUNTIME" = "podman" ]; then
            if echo "$DRY_OUT" | grep -q "^DOCKER_HOST=unix:///run/podman/podman.sock "; then
                _pass "dry-run sets DOCKER_HOST for podman"
            else
                _fail "dry-run sets DOCKER_HOST for podman" "${DRY_OUT:0:300}"
            fi
        elif echo "$DRY_OUT" | grep -q "DOCKER_HOST"; then
            _fail "dry-run leaves DOCKER_HOST unset for docker" "${DRY_OUT:0:300}"
        else
            _pass "dry-run leaves DOCKER_HOST unset for docker"
        fi
        assert_run "dry-run quotes args with spaces" 0 'logs my\ svc' -- -n omvtest_compose logs "my svc"

        # Real runs
        assert_run "omv-compose-run config --services" 0 "hello" -- omvtest_compose config --services
        RUN_LOG_LINE=$(tail -n 1 /var/log/omv-compose-run.log 2>/dev/null || true)
        if echo "$RUN_LOG_LINE" | grep -q "\[composerun\] .*docker compose --file $RUN_DIR/omvtest_compose.yml .* config --services$"; then
            _pass "omv-compose-run logs the command it runs"
        else
            _fail "omv-compose-run logs the command it runs" "last log line: ${RUN_LOG_LINE:0:300}"
        fi
        RUN_LOG_COUNT=$(wc -l < /var/log/omv-compose-run.log 2>/dev/null || echo 0)
        assert_run "omv-compose-run --no-log runs the command" 0 "hello" -- --no-log omvtest_compose config --services
        if [ "$(wc -l < /var/log/omv-compose-run.log 2>/dev/null || echo 0)" = "$RUN_LOG_COUNT" ]; then
            _pass "omv-compose-run --no-log does not log"
        else
            _fail "omv-compose-run --no-log does not log" "log grew: $(tail -n 1 /var/log/omv-compose-run.log)"
        fi
        RUN_EC=0
        "$RUN_CMD" omvtest_compose config --omvtest-bogus-flag >/dev/null 2>&1 || RUN_EC=$?
        if [ $RUN_EC -ne 0 ] && [ $RUN_EC -ne 13 ]; then
            _pass "omv-compose-run passes through compose exit code ($RUN_EC)"
        else
            _fail "omv-compose-run passes through compose exit code" "got exit $RUN_EC"
        fi

        # Override + env file are both applied: the override reads a variable
        # that only exists in the stack env file.
        cp -p "$RUN_DIR/omvtest_compose.env" "$RUN_DIR/omvtest_compose.env.omvtest_bak"
        RUN_OVR_BAK=""
        if [ -f "$RUN_DIR/compose.override.yml" ]; then
            RUN_OVR_BAK="$RUN_DIR/compose.override.yml.omvtest_bak"
            cp -p "$RUN_DIR/compose.override.yml" "$RUN_OVR_BAK"
        fi
        echo "OMVTEST_RUN_VAR=from_stack_env" >> "$RUN_DIR/omvtest_compose.env"
        cat > "$RUN_DIR/compose.override.yml" <<'EOF'
services:
  hello:
    environment:
      OMVTEST_RUN_OVR: "${OMVTEST_RUN_VAR:-unset}"
EOF
        assert_run "dry-run adds --file for override" 0 \
            "--file $RUN_DIR/compose.override.yml" -- -n omvtest_compose config
        assert_run "config applies override and stack env" 0 \
            "OMVTEST_RUN_OVR: from_stack_env" -- omvtest_compose config
        if [ -n "$RUN_OVR_BAK" ]; then
            mv -f "$RUN_OVR_BAK" "$RUN_DIR/compose.override.yml"
        else
            rm -f "$RUN_DIR/compose.override.yml"
        fi
        mv -f "$RUN_DIR/omvtest_compose.env.omvtest_bak" "$RUN_DIR/omvtest_compose.env"
    fi
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

# --- importPortainerStacks (synchronous) -------------------------------------
assert_rpc_fails "importPortainerStacks (no credentials) fails" "Compose" "importPortainerStacks" \
    '{"url":"https://invalid-host-omvtest.local:9443","sslverify":false}' "API key"
assert_rpc_fails "importPortainerStacks (unreachable host) fails" "Compose" "importPortainerStacks" \
    '{"url":"https://invalid-host-omvtest.local:9443","apikey":"ptr_test","sslverify":false}'

# --- Synchronous importExistingOne / importExistingFolder --------------------
SYNC_DIR="$IMPORT_TMP/sync"
_make_stack "$SYNC_DIR/omvtest_import_sync1" "compose.yml"
echo "OMVTEST_SYNC=1" > "$SYNC_DIR/omvtest_import_sync1/.env"
assert_rpc "importExistingOne" "Compose" "importExistingOne" \
    "{\"path\":\"$SYNC_DIR/omvtest_import_sync1\"}"
sync1_uuid=$(recover_uuid_from_list "Compose" "getFileList" "name" "omvtest_import_sync1")
if [ -n "$sync1_uuid" ]; then
    IMPORT_UUIDS+=("$sync1_uuid")
    assert_rpc "importExistingOne imported the .env file" "Compose" "getFile" \
        "{\"uuid\":\"$sync1_uuid\"}" "OMVTEST_SYNC=1"
else
    _fail "importExistingOne imported the .env file" "omvtest_import_sync1 not found"
fi
assert_rpc_fails "importExistingOne (duplicate) fails" "Compose" "importExistingOne" \
    "{\"path\":\"$SYNC_DIR/omvtest_import_sync1\"}" "already exists"
assert_rpc_fails "importExistingOne (no compose file) fails" "Compose" "importExistingOne" \
    "{\"path\":\"$IMPORT_TMP\"}" "No compose file found"

# omvtest_import_sync1 is already imported and must be skipped silently.
_make_stack "$SYNC_DIR/omvtest_import_sync2" "omvtest_import_sync2.yml"
printf 'services:\n  hello:\n    restart: "no"\n' > "$SYNC_DIR/omvtest_import_sync2/compose.override.yml"
assert_rpc "importExistingFolder" "Compose" "importExistingFolder" "{\"path\":\"$SYNC_DIR\"}"
sync2_uuid=$(recover_uuid_from_list "Compose" "getFileList" "name" "omvtest_import_sync2")
if [ -n "$sync2_uuid" ]; then
    IMPORT_UUIDS+=("$sync2_uuid")
    assert_rpc "importExistingFolder imported the override file" "Compose" "getFile" \
        "{\"uuid\":\"$sync2_uuid\"}" 'restart: \\"no\\"'
else
    _fail "importExistingFolder imported the override file" "omvtest_import_sync2 not found"
fi

# --- importConfig ------------------------------------------------------------
# The stack's own files (<dir>.yml, <dir>.env, compose.override.yml) must not
# be imported as config snippets; everything else is.
if [ -n "$FILE_UUID" ]; then
    CFG_DIR="$IMPORT_TMP/omvtest_cfgimport"
    mkdir -p "$CFG_DIR/subdir"
    echo "services: {}" > "$CFG_DIR/omvtest_cfgimport.yml"
    echo "A=1" > "$CFG_DIR/omvtest_cfgimport.env"
    echo "services: {}" > "$CFG_DIR/compose.override.yml"
    echo "omvtest config" > "$CFG_DIR/omvtest_cfg_a.conf"
    assert_rpc "importConfig" "Compose" "importConfig" \
        "{\"path\":\"$CFG_DIR\",\"fileref\":\"$FILE_UUID\"}"
    CFG_LIST=$(omv-rpc -u admin "Compose" "getConfigList" \
        '{"start":0,"limit":1000,"sortfield":"name","sortdir":"ASC"}' 2>/dev/null)
    cfg_uuid() {
        echo "$CFG_LIST" | python3 -c "
import sys, json
for r in json.load(sys.stdin)['data']:
    if r['name'] == '$1' and r['fileref'] == '$FILE_UUID':
        print(r['uuid'])" 2>/dev/null
    }
    a_uuid=$(cfg_uuid omvtest_cfg_a.conf)
    if [ -n "$a_uuid" ]; then
        EXTRA_CONFIG_UUIDS+=("$a_uuid")
        _pass "importConfig imported omvtest_cfg_a.conf"
    else
        _fail "importConfig imported omvtest_cfg_a.conf" "not found in getConfigList"
    fi
    for skipped in omvtest_cfgimport.yml omvtest_cfgimport.env compose.override.yml subdir; do
        bad_uuid=$(cfg_uuid "$skipped")
        if [ -z "$bad_uuid" ]; then
            _pass "importConfig skipped $skipped"
        else
            EXTRA_CONFIG_UUIDS+=("$bad_uuid")
            _fail "importConfig skipped $skipped" "imported as config $bad_uuid"
        fi
    done
else
    _skip "importConfig" "no file uuid"
fi

# --- importDockerfile --------------------------------------------------------
DF_DIR="$IMPORT_TMP/dockerfiles"
mkdir -p "$DF_DIR/omvtest_dfimport" "$DF_DIR/omvtest_not_a_dockerfile"
printf 'FROM scratch\n# omvtest_dfimport\n' > "$DF_DIR/omvtest_dfimport/Dockerfile"
assert_rpc "importDockerfile" "Compose" "importDockerfile" "{\"path\":\"$DF_DIR\"}"
df_uuid=$(recover_uuid_from_list "Compose" "getDockerfileList" "name" "omvtest_dfimport")
if [ -n "$df_uuid" ]; then
    EXTRA_DOCKERFILE_UUIDS+=("$df_uuid")
    assert_rpc "importDockerfile imported the Dockerfile body" "Compose" "getDockerfile" \
        "{\"uuid\":\"$df_uuid\"}" "# omvtest_dfimport"
else
    _fail "importDockerfile imported the Dockerfile body" "omvtest_dfimport not found"
fi
if [ -n "$(recover_uuid_from_list "Compose" "getDockerfileList" "name" "omvtest_not_a_dockerfile")" ]; then
    _fail "importDockerfile skips folders without a Dockerfile" "omvtest_not_a_dockerfile imported"
else
    _pass "importDockerfile skips folders without a Dockerfile"
fi

# --- Import RPCs require the admin role ---------------------------------------
# Regression: importConfig, importExistingFolder and importExistingOne had no
# context check, so any user could read files into the config database. Use
# an empty directory so nothing is imported even if the check is missing.
EMPTY_DIR="$IMPORT_TMP/empty"
mkdir -p "$EMPTY_DIR"
for m in importConfig importExistingFolder importExistingOne importDockerfile; do
    assert_rpc_fails "$m requires the admin role" "Compose" "$m" \
        "{\"path\":\"$EMPTY_DIR\",\"fileref\":\"\"}" "Invalid context role" "$NONADMIN_USER"
done

# --- setUrl (a local path works like a URL for file_get_contents) ------------
URL_FILE="$IMPORT_TMP/omvtest_url.yml"
printf 'services:\n  web:\n    image: hello-world\n    env_file: web.env\n' > "$URL_FILE"
assert_rpc "setUrl" "Compose" "setUrl" \
    "{\"name\":\"omvtest_url_compose\",\"description\":\"RPC test\",\"url\":\"$URL_FILE\"}"
url_uuid=$(json_uuid "$RPC_OUT")
[ -z "$url_uuid" ] && url_uuid=$(recover_uuid_from_list "Compose" "getFileList" "name" "omvtest_url_compose")
if [ -n "$url_uuid" ]; then
    EXTRA_FILE_UUIDS+=("$url_uuid")
    assert_rpc "setUrl comments out env_file" "Compose" "getFile" "{\"uuid\":\"$url_uuid\"}" "#env_file: web.env"
else
    _fail "setUrl comments out env_file" "omvtest_url_compose not found"
fi
assert_rpc_fails "setUrl (duplicate name) fails" "Compose" "setUrl" \
    "{\"name\":\"omvtest_url_compose\",\"description\":\"RPC test\",\"url\":\"$URL_FILE\"}"

# --- getExampleList / setExample (needs internet; empty list offline) --------
assert_rpc "getExampleList" "Compose" "getExampleList" '{}'
EXAMPLE=$(echo "$RPC_OUT" | python3 -c "
import sys, json
l = json.load(sys.stdin)
print(l[0]['name'] if l else '')" 2>/dev/null)
if [ -n "$EXAMPLE" ]; then
    assert_rpc "setExample ($EXAMPLE)" "Compose" "setExample" \
        "{\"name\":\"omvtest_example\",\"description\":\"RPC test\",\"example\":\"$EXAMPLE\"}" \
        '"body": *"[^"]'
    ex_uuid=$(json_uuid "$RPC_OUT")
    [ -z "$ex_uuid" ] && ex_uuid=$(recover_uuid_from_list "Compose" "getFileList" "name" "omvtest_example")
    [ -n "$ex_uuid" ] && EXTRA_FILE_UUIDS+=("$ex_uuid")
else
    _skip "setExample" "example list is empty (no internet access?)"
fi

# --- importChanges: pull hand edits of the on-disk files into the DB ---------
if [ -n "$FILE_UUID" ] && [ -f "$SF_PATH/omvtest_compose/omvtest_compose.yml" ]; then
    echo "# omvtest_importchanges_marker" >> "$SF_PATH/omvtest_compose/omvtest_compose.yml"
    assert_rpc "importChanges" "Compose" "importChanges" "{\"uuid\":\"$FILE_UUID\"}" \
        "omvtest_importchanges_marker"
else
    _skip "importChanges" "no omvtest_compose file on disk"
fi

# ---------------------------------------------------------------------------
# 13. Shared folder path change propagation (regression test)
# ---------------------------------------------------------------------------
# A compose file can reference a shared folder purely through a
# ${{ sf:"name" }} placeholder inside its body (e.g. a bind-mount volume)
# without that shared folder ever being the file's own storage location.
# When such a shared folder's path later changes — its reldirpath is edited,
# or (as in the field report below) its disk is replaced and the share is
# recreated — the compose module must be marked dirty and a redeploy must
# re-render the on-disk file with the shared folder's *new* absolute path.
#
# https://forum.openmediavault.org/index.php?thread/59557-download-disk-replaced-shares-updated-but-compose-still-references-old-disk/
section "Shared folder path change propagation"

# Borrow the mount point of the already-configured compose storage shared
# folder (this script requires it to be set) so the test shared folder lands
# on a filesystem that is guaranteed to exist and be writable.
COMPOSE_SF_UUID=$(json_get "$SETTINGS" "sharedfolderref")
MNTENTREF=""
COMPOSE_STORAGE=""
if [ -n "$COMPOSE_SF_UUID" ] && [ "$COMPOSE_SF_UUID" != "null" ]; then
    MNTENTREF=$(omv-rpc -u admin "ShareMgmt" "get" "{\"uuid\":\"$COMPOSE_SF_UUID\"}" 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('mntentref',''))" 2>/dev/null || echo "")
    COMPOSE_STORAGE=$(get_sf_path "$COMPOSE_SF_UUID")
fi

if [ -z "$MNTENTREF" ]; then
    _skip "setSharedFolder (create omvtest_sfpath_download)" "no compose shared folder configured to borrow a mount point from"
    _skip "on-disk compose file resolves sf placeholder to initial path" "no mount point"
    _skip "setSharedFolder (change reldirpath)" "no mount point"
    _skip "getPath reflects the new relative path" "no mount point"
    _skip "compose module is marked dirty after shared folder path change" "no mount point"
    _skip "on-disk compose file resolves sf placeholder to new path after redeploy" "no mount point"
    _skip "on-disk compose file no longer references the old path" "no mount point"
else
    SF_PARAMS=$(python3 -c "
import json
print(json.dumps({
    'uuid': '$OMV_NEW_UUID',
    'name': 'omvtest_sfpath_download',
    'reldirpath': 'omvtest_sfpath_download/',
    'comment': 'RPC test - sf path change',
    'mntentref': '$MNTENTREF'
}))
")
    assert_rpc "setSharedFolder (create omvtest_sfpath_download)" "ShareMgmt" "set" "$SF_PARAMS"
    SFPATH_SF_UUID=$(json_uuid "$RPC_OUT")
    if [ -z "$SFPATH_SF_UUID" ]; then
        SFPATH_SF_UUID=$(recover_uuid_from_list "ShareMgmt" "getList" "name" "omvtest_sfpath_download")
    fi
    info "Created shared folder uuid=$SFPATH_SF_UUID"

    if [ -z "$SFPATH_SF_UUID" ]; then
        _skip "on-disk compose file resolves sf placeholder to initial path" "no shared folder uuid"
        _skip "setSharedFolder (change reldirpath)" "no shared folder uuid"
        _skip "getPath reflects the new relative path" "no shared folder uuid"
        _skip "compose module is marked dirty after shared folder path change" "no shared folder uuid"
        _skip "on-disk compose file resolves sf placeholder to new path after redeploy" "no shared folder uuid"
        _skip "on-disk compose file no longer references the old path" "no shared folder uuid"
    else
        SFPATH_ORIG_PATH=$(get_sf_path "$SFPATH_SF_UUID")
        info "Shared folder initial path: $SFPATH_ORIG_PATH"

        SF_COMPOSE_BODY='services:
  hello:
    image: hello-world
    restart: unless-stopped
    volumes:
      - ${{ sf:"omvtest_sfpath_download" }}:/download'

        COMPOSE_PARAMS=$(python3 -c "
import json
print(json.dumps({
    'name': 'omvtest_sfpath_compose',
    'description': 'RPC test - sf path change',
    'body': '''$SF_COMPOSE_BODY''',
    'showenv': False,
    'env': '',
    'showoverride': False,
    'override': ''
}))
")
        assert_rpc "setFile (create, references sf placeholder)" "Compose" "setFile" "$COMPOSE_PARAMS"
        SFPATH_COMPOSE_UUID=$(json_uuid "$RPC_OUT")
        if [ -z "$SFPATH_COMPOSE_UUID" ]; then
            SFPATH_COMPOSE_UUID=$(recover_uuid_from_list "Compose" "getFileList" "name" "omvtest_sfpath_compose")
        fi
        info "Created compose file uuid=$SFPATH_COMPOSE_UUID"

        if [ -z "$SFPATH_COMPOSE_UUID" ]; then
            _skip "on-disk compose file resolves sf placeholder to initial path" "no compose file uuid"
            _skip "setSharedFolder (change reldirpath)" "no compose file uuid"
            _skip "getPath reflects the new relative path" "no compose file uuid"
            _skip "compose module is marked dirty after shared folder path change" "no compose file uuid"
            _skip "on-disk compose file resolves sf placeholder to new path after redeploy" "no compose file uuid"
            _skip "on-disk compose file no longer references the old path" "no compose file uuid"
        else
            COMPOSE_YML="$COMPOSE_STORAGE/omvtest_sfpath_compose/omvtest_sfpath_compose.yml"

            # setFile already deploys synchronously on create (Config.applyChanges
            # force=true), but run the CLI deploy too — this is the step a user
            # actually runs, and it must be a no-op here since nothing is stale yet.
            info "Deploying compose module"
            omv-salt deploy run compose --quiet >/dev/null 2>&1

            if [ -f "$COMPOSE_YML" ] && grep -qF "$SFPATH_ORIG_PATH:/download" "$COMPOSE_YML"; then
                _pass "on-disk compose file resolves sf placeholder to initial path"
            else
                _fail "on-disk compose file resolves sf placeholder to initial path" \
                    "expected '$SFPATH_ORIG_PATH:/download' in $COMPOSE_YML"
            fi

            # --- Change the shared folder's relative path -------------------
            SF_UPDATE_PARAMS=$(python3 -c "
import json
print(json.dumps({
    'uuid': '$SFPATH_SF_UUID',
    'name': 'omvtest_sfpath_download',
    'reldirpath': 'omvtest_sfpath_download_moved/',
    'comment': 'RPC test - sf path change (moved)',
    'mntentref': '$MNTENTREF'
}))
")
            assert_rpc "setSharedFolder (change reldirpath)" "ShareMgmt" "set" "$SF_UPDATE_PARAMS"

            SFPATH_NEW_PATH=$(get_sf_path "$SFPATH_SF_UUID")
            info "Shared folder new path: $SFPATH_NEW_PATH"

            if [ -n "$SFPATH_NEW_PATH" ] && [ "$SFPATH_NEW_PATH" != "$SFPATH_ORIG_PATH" ]; then
                _pass "getPath reflects the new relative path"
            else
                _fail "getPath reflects the new relative path" "path unchanged: '$SFPATH_NEW_PATH'"
            fi

            # --- The compose module must be marked dirty ---------------------
            # This is the actual regression: the compose module's
            # onSharedFolder() listener only marks the module dirty when the
            # sharedfolder is a file's own storage location, never when it is
            # only referenced via a ${{ sf:"..." }} placeholder in the body.
            # Without the dirty flag, OMV's "Apply configuration changes"
            # banner never appears, so nothing prompts the user to redeploy.
            dirty_out=$(omv-rpc -u admin "Config" "isDirty" '{"modules":["compose"]}' 2>&1)
            if echo "$dirty_out" | grep -qi 'true'; then
                _pass "compose module is marked dirty after shared folder path change"
            else
                _fail "compose module is marked dirty after shared folder path change" \
                    "Config isDirty returned: ${dirty_out:0:200}"
            fi

            # --- Redeploy and confirm the on-disk file now uses the new path -
            info "Re-deploying compose module"
            omv-salt deploy run compose --quiet >/dev/null 2>&1

            if [ -f "$COMPOSE_YML" ] && grep -qF "$SFPATH_NEW_PATH:/download" "$COMPOSE_YML"; then
                _pass "on-disk compose file resolves sf placeholder to new path after redeploy"
            else
                _fail "on-disk compose file resolves sf placeholder to new path after redeploy" \
                    "expected '$SFPATH_NEW_PATH:/download' in $COMPOSE_YML"
            fi
            if [ -f "$COMPOSE_YML" ] && grep -qF "$SFPATH_ORIG_PATH:/download" "$COMPOSE_YML"; then
                _fail "on-disk compose file no longer references the old path" \
                    "stale path '$SFPATH_ORIG_PATH' still present in $COMPOSE_YML"
            else
                _pass "on-disk compose file no longer references the old path"
            fi
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 13b. Bad compose.yml / .env symlinks are overwritten on deploy
# ---------------------------------------------------------------------------
# Regression: copying the compose shared folder with a symlink-following
# tool (cp -r, rsync -L) turns compose.yml and .env into regular files, and
# salt's file.symlink then failed with "File exists where the symlink ...
# should be", breaking the whole deploy. Stale links left over from a move
# to a new drive must be repointed as well.
#
# https://forum.openmediavault.org/index.php?thread/59582-what-is-the-correct-procedure-to-move-docker-appdata-share-to-a-new-drive/
section "Symlink overwrite"

SYMLINK_TESTS=(
    "deploy succeeds with regular files in place of symlinks"
    "compose.yml regular file replaced by symlink"
    ".env regular file replaced by symlink"
    "deploy succeeds with stale symlinks"
    "compose.yml stale symlink repointed"
    ".env stale symlink repointed"
)

[ -z "$COMPOSE_STORAGE" ] && [ -n "$COMPOSE_SF_UUID" ] && COMPOSE_STORAGE=$(get_sf_path "$COMPOSE_SF_UUID")
CREATE_SYMLINKS=$(json_get "$SETTINGS" "createsymlinks")
SYMLINK_DIR="$COMPOSE_STORAGE/omvtest_compose"

# Assert $1 is a symlink whose target is exactly $2.
assert_symlink() {
    local desc=$1 link=$2 target=$3
    if [ -L "$link" ] && [ "$(readlink "$link")" = "$target" ]; then
        _pass "$desc"
    elif [ -L "$link" ]; then
        _fail "$desc" "$link -> $(readlink "$link"), expected $target"
    else
        _fail "$desc" "$link is not a symlink"
    fi
}

# Run the compose deploy and assert it exits cleanly.
assert_deploy() {
    local desc=$1 out ec=0
    out=$(omv-salt deploy run compose --quiet 2>&1) || ec=$?
    if [ $ec -eq 0 ] && ! echo "$out" | grep -q "File exists where the symlink"; then
        _pass "$desc"
    else
        _fail "$desc" "$(echo "$out" | grep -m2 -i "symlink\|fail\|error")"
    fi
}

if [ "$CREATE_SYMLINKS" != "True" ] && [ "$CREATE_SYMLINKS" != "true" ] && [ "$CREATE_SYMLINKS" != "1" ]; then
    for t in "${SYMLINK_TESTS[@]}"; do _skip "$t" "createsymlinks disabled in settings"; done
elif [ -z "$FILE_UUID" ] || [ -z "$COMPOSE_STORAGE" ] || [ ! -d "$SYMLINK_DIR" ]; then
    for t in "${SYMLINK_TESTS[@]}"; do _skip "$t" "no omvtest_compose directory"; done
else
    SYMLINK_YML="$SYMLINK_DIR/compose.yml"
    SYMLINK_ENV="$SYMLINK_DIR/.env"

    # --- Dereferenced copies: regular files where the symlinks belong -------
    rm -f "$SYMLINK_YML" "$SYMLINK_ENV"
    cp "$SYMLINK_DIR/omvtest_compose.yml" "$SYMLINK_YML"
    cp "$SYMLINK_DIR/omvtest_compose.env" "$SYMLINK_ENV"
    info "Replaced compose.yml and .env with regular files"

    assert_deploy "deploy succeeds with regular files in place of symlinks"
    assert_symlink "compose.yml regular file replaced by symlink" \
        "$SYMLINK_YML" "$SYMLINK_DIR/omvtest_compose.yml"
    assert_symlink ".env regular file replaced by symlink" \
        "$SYMLINK_ENV" "$SYMLINK_DIR/omvtest_compose.env"

    # --- Stale symlinks still pointing at the old drive ---------------------
    ln -sfn "/srv/omvtest-old-drive/omvtest_compose/omvtest_compose.yml" "$SYMLINK_YML"
    ln -sfn "/srv/omvtest-old-drive/omvtest_compose/omvtest_compose.env" "$SYMLINK_ENV"
    info "Pointed compose.yml and .env at a nonexistent old drive"

    assert_deploy "deploy succeeds with stale symlinks"
    assert_symlink "compose.yml stale symlink repointed" \
        "$SYMLINK_YML" "$SYMLINK_DIR/omvtest_compose.yml"
    assert_symlink ".env stale symlink repointed" \
        "$SYMLINK_ENV" "$SYMLINK_DIR/omvtest_compose.env"
fi

# ---------------------------------------------------------------------------
# 13c. CHANGE_TO_COMPOSE_DATA_PATH is replaced in the on-disk files
# ---------------------------------------------------------------------------
# The DB keeps the raw placeholder; the salt deploy must substitute the data
# shared folder path into the rendered compose, env and override files.
section "Data path placeholder"

DATAPATH_TESTS=(
    "setFile (create, uses CHANGE_TO_COMPOSE_DATA_PATH)"
    "getFile keeps raw CHANGE_TO_COMPOSE_DATA_PATH in DB"
    "compose file: data path substituted"
    "env file: data path substituted"
    "override file: data path substituted"
    "no CHANGE_TO_COMPOSE_DATA_PATH left in on-disk files"
)

[ -z "$COMPOSE_STORAGE" ] && [ -n "$COMPOSE_SF_UUID" ] && COMPOSE_STORAGE=$(get_sf_path "$COMPOSE_SF_UUID")
DATA_SF_UUID=$(json_get "$SETTINGS" "datasharedfolderref")
DATA_PATH=""
if [ -n "$DATA_SF_UUID" ] && [ "$DATA_SF_UUID" != "null" ]; then
    DATA_PATH=$(get_sf_path "$DATA_SF_UUID")
fi

DP_COMPOSE_BODY='services:
  hello:
    image: hello-world
    restart: unless-stopped
    volumes:
      - CHANGE_TO_COMPOSE_DATA_PATH/omvtest_datapath:/data'
DP_COMPOSE_ENV='OMVTEST_DATA=CHANGE_TO_COMPOSE_DATA_PATH/omvtest_datapath_env'
DP_COMPOSE_OVERRIDE='services:
  hello:
    volumes:
      - CHANGE_TO_COMPOSE_DATA_PATH/omvtest_datapath_override:/override'

DP_PARAMS=$(python3 -c "
import json
print(json.dumps({
    'name': 'omvtest_datapath_compose',
    'description': 'RPC test - data path placeholder',
    'body': '''$DP_COMPOSE_BODY''',
    'showenv': True,
    'env': '''$DP_COMPOSE_ENV''',
    'showoverride': True,
    'override': '''$DP_COMPOSE_OVERRIDE'''
}))
")

if [ -z "$COMPOSE_STORAGE" ]; then
    for t in "${DATAPATH_TESTS[@]}"; do _skip "$t" "no compose shared folder path"; done
elif [ -z "$DATA_PATH" ]; then
    # Without a data shared folder, setFile must refuse the placeholder.
    assert_rpc_fails "setFile rejects CHANGE_TO_COMPOSE_DATA_PATH without data shared folder" \
        "Compose" "setFile" "$DP_PARAMS"
    for t in "${DATAPATH_TESTS[@]}"; do _skip "$t" "no data shared folder set in settings"; done
else
    info "Data shared folder path: $DATA_PATH"
    assert_rpc "setFile (create, uses CHANGE_TO_COMPOSE_DATA_PATH)" "Compose" "setFile" "$DP_PARAMS"
    DATAPATH_COMPOSE_UUID=$(json_uuid "$RPC_OUT")
    if [ -z "$DATAPATH_COMPOSE_UUID" ]; then
        DATAPATH_COMPOSE_UUID=$(recover_uuid_from_list "Compose" "getFileList" "name" "omvtest_datapath_compose")
    fi
    info "Created compose file uuid=$DATAPATH_COMPOSE_UUID"

    if [ -z "$DATAPATH_COMPOSE_UUID" ]; then
        for t in "${DATAPATH_TESTS[@]:1}"; do _skip "$t" "no compose file uuid"; done
    else
        assert_rpc "getFile keeps raw CHANGE_TO_COMPOSE_DATA_PATH in DB" "Compose" "getFile" \
            "{\"uuid\":\"$DATAPATH_COMPOSE_UUID\"}" 'CHANGE_TO_COMPOSE_DATA_PATH'

        info "Deploying compose module"
        omv-salt deploy run compose --quiet >/dev/null 2>&1

        DP_DIR="$COMPOSE_STORAGE/omvtest_datapath_compose"
        DP_YML="$DP_DIR/omvtest_datapath_compose.yml"
        DP_ENV="$DP_DIR/omvtest_datapath_compose.env"
        DP_OVR="$DP_DIR/compose.override.yml"

        assert_file_contains "compose file: data path substituted" \
            "$DP_YML" "$DATA_PATH/omvtest_datapath:/data"
        assert_file_contains "env file: data path substituted" \
            "$DP_ENV" "OMVTEST_DATA=$DATA_PATH/omvtest_datapath_env"
        assert_file_contains "override file: data path substituted" \
            "$DP_OVR" "$DATA_PATH/omvtest_datapath_override:/override"

        leftover=$(grep -lF "CHANGE_TO_COMPOSE_DATA_PATH" "$DP_YML" "$DP_ENV" "$DP_OVR" 2>/dev/null)
        if [ -z "$leftover" ]; then
            _pass "no CHANGE_TO_COMPOSE_DATA_PATH left in on-disk files"
        else
            _fail "no CHANGE_TO_COMPOSE_DATA_PATH left in on-disk files" \
                "placeholder still present in: $(echo $leftover)"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 13d. System-wide RPCs (opt-in)
# ---------------------------------------------------------------------------
section "System-wide RPCs (opt-in)"

DESTRUCTIVE_TESTS=("doPrune (network prune)" "doDownAll" "doGit (init)" "restartDocker"
    "runtime is back after restartDocker" "enableDockerRepo")
if [ "${OMVTEST_DESTRUCTIVE:-0}" != "1" ]; then
    for t in "${DESTRUCTIVE_TESTS[@]}"; do _skip "$t" "set OMVTEST_DESTRUCTIVE=1 to run"; done
else
    assert_rpc_bg "doPrune (network prune)" "Compose" "doPrune" '{"command":"network prune"}'
    assert_rpc_bg "doDownAll" "Compose" "doDownAll" '{}'
    if [ -d "$SF_PATH/.git" ]; then
        _skip "doGit (init)" "compose shared folder is already a git repo"
    else
        assert_rpc_bg "doGit (init)" "Compose" "doGit" '{"uuid":"","command":"init"}'
    fi
    assert_rpc "restartDocker" "Compose" "restartDocker" '{}'
    up=0
    for _ in $(seq 1 30); do
        "$RUNTIME" info >/dev/null 2>&1 && { up=1; break; }
        sleep 2
    done
    if [ $up -eq 1 ]; then
        _pass "runtime is back after restartDocker"
    else
        _fail "runtime is back after restartDocker" "'$RUNTIME info' still failing after 60s"
    fi
    assert_rpc_bg "enableDockerRepo" "Compose" "enableDockerRepo" '{}'
fi

if [ "${OMVTEST_REINSTALL_DOCKER:-0}" != "1" ]; then
    _skip "reinstallDocker" "set OMVTEST_REINSTALL_DOCKER=1 to run"
else
    assert_rpc_bg "reinstallDocker" "Compose" "reinstallDocker" '{}'
fi

# ---------------------------------------------------------------------------
# 14. Delete test objects (also done by cleanup trap, but verify RPCs work)
# ---------------------------------------------------------------------------
section "Delete test objects"

if [ -n "$JOB_UUID" ]; then
    assert_rpc "deleteJob" "Compose" "deleteJob" "{\"uuid\":\"$JOB_UUID\"}" && JOB_UUID=""
fi

if [ -n "$JOB_RUN_UUID" ]; then
    assert_rpc "deleteJob (doJob test job)" "Compose" "deleteJob" "{\"uuid\":\"$JOB_RUN_UUID\"}" && JOB_RUN_UUID=""
fi

if [ -n "$CONFIG_UUID" ]; then
    assert_rpc "deleteConfig" "Compose" "deleteConfig" "{\"uuid\":\"$CONFIG_UUID\"}" && CONFIG_UUID=""
    if [ -e "$SF_PATH/omvtest_compose/omvtest_config" ]; then
        _fail "deleteConfig removed the file on disk" "$SF_PATH/omvtest_compose/omvtest_config still exists"
    else
        _pass "deleteConfig removed the file on disk"
    fi
fi

if [ -n "$DOCKERFILE_UUID" ]; then
    assert_rpc "deleteDockerfile" "Compose" "deleteDockerfile" "{\"uuid\":\"$DOCKERFILE_UUID\"}" && DOCKERFILE_UUID=""
    # Regression: deleteDockerfile tried to remove an undefined directory
    # variable, so the Dockerfile's folder was left behind.
    if [ -e "$SF_PATH/omvtest_dockerfile" ]; then
        _fail "deleteDockerfile removed the Dockerfile folder" "$SF_PATH/omvtest_dockerfile still exists"
    else
        _pass "deleteDockerfile removed the Dockerfile folder"
    fi
fi

# Config snippets created by the coverage tests reference omvtest_compose.
for uuid in "${EXTRA_CONFIG_UUIDS[@]}"; do
    omv-rpc -u admin "Compose" "deleteConfig" "{\"uuid\":\"$uuid\"}" >/dev/null 2>&1 || true
done
EXTRA_CONFIG_UUIDS=()

if [ -n "$FILE_UUID" ]; then
    assert_rpc "deleteFile" "Compose" "deleteFile" "{\"uuid\":\"$FILE_UUID\"}" && FILE_UUID=""
    for f in omvtest_compose.yml omvtest_compose.env compose.override.yml compose.yml .env; do
        if [ -e "$SF_PATH/omvtest_compose/$f" ] || [ -L "$SF_PATH/omvtest_compose/$f" ]; then
            _fail "deleteFile removed $f" "$SF_PATH/omvtest_compose/$f still exists"
        else
            _pass "deleteFile removed $f"
        fi
    done
fi

if [ -n "$SFPATH_COMPOSE_UUID" ]; then
    assert_rpc "deleteFile (sf-path-change compose file)" "Compose" "deleteFile" \
        "{\"uuid\":\"$SFPATH_COMPOSE_UUID\"}" && SFPATH_COMPOSE_UUID=""
fi

if [ -n "$DATAPATH_COMPOSE_UUID" ]; then
    assert_rpc "deleteFile (data-path compose file)" "Compose" "deleteFile" \
        "{\"uuid\":\"$DATAPATH_COMPOSE_UUID\"}" && DATAPATH_COMPOSE_UUID=""
fi

if [ -n "$SFPATH_SF_UUID" ]; then
    assert_rpc "deleteSharedFolder (sf-path-change shared folder)" "ShareMgmt" "delete" \
        "{\"uuid\":\"$SFPATH_SF_UUID\",\"recursive\":true}" && SFPATH_SF_UUID=""
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
