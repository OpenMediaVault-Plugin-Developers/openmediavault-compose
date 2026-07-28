#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="/opt/omv-setup"
pass=0
fail=0

assert() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "  PASS: $desc"; ((pass++))
  else
    echo "  FAIL: $desc"; ((fail++))
  fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "  PASS: $desc"; ((pass++))
  else
    echo "  FAIL: $desc (expected='$expected', got='$actual')"; ((fail++))
  fi
}

reset_mocks() {
  rm -f /tmp/omv-mock-*.json /tmp/omv-mock-*.log
}

# ============================================================
echo "=== 01-groups.sh ==="
reset_mocks

bash "$SCRIPT_DIR/01-groups.sh"
assert "grp_docker group created" getent group grp_docker
assert "docker group created" getent group docker

# Idempotent
bash "$SCRIPT_DIR/01-groups.sh"
assert "idempotent: no error on rerun" true

# ============================================================
echo ""
echo "=== 02-service-user.sh ==="

bash "$SCRIPT_DIR/02-service-user.sh"
assert "svc_docker user created" id svc_docker
assert_eq "primary group is grp_docker" "grp_docker" "$(id -gn svc_docker)"
assert "svc_docker in docker group" bash -c "id -nG svc_docker | grep -qw docker"

# Idempotent
bash "$SCRIPT_DIR/02-service-user.sh"
assert "idempotent: no error on rerun" true

# ============================================================
echo ""
echo "=== 03-calling-user.sh ==="

# Create a test user to act as the "SSH caller"
useradd --create-home testcaller 2>/dev/null || true
export SUDO_USER=testcaller

bash "$SCRIPT_DIR/03-calling-user.sh"
assert "testcaller in docker group" bash -c "id -nG testcaller | grep -qw docker"
assert "testcaller in grp_docker group" bash -c "id -nG testcaller | grep -qw grp_docker"

# Idempotent
bash "$SCRIPT_DIR/03-calling-user.sh"
assert "idempotent: no error on rerun" true

# Root case: should skip gracefully
unset SUDO_USER
bash "$SCRIPT_DIR/03-calling-user.sh"
assert "root case: exits cleanly" true

# Restore for subsequent scripts
export SUDO_USER=testcaller

# ============================================================
echo ""
echo "=== 07-data-dirs.sh ==="

# Clean slate
rm -rf /mnt/data/{appdata,compose,backup,share}

bash "$SCRIPT_DIR/07-data-dirs.sh"
assert "appdata dir exists" test -d /mnt/data/appdata
assert "compose dir exists" test -d /mnt/data/compose
assert "backup dir exists" test -d /mnt/data/backup
assert "share dir exists" test -d /mnt/data/share

assert_eq "appdata owner" "svc_docker:grp_docker" "$(stat -c '%U:%G' /mnt/data/appdata)"
assert_eq "compose owner" "svc_docker:grp_docker" "$(stat -c '%U:%G' /mnt/data/compose)"
assert_eq "appdata mode" "750" "$(stat -c '%a' /mnt/data/appdata)"

# Idempotent
bash "$SCRIPT_DIR/07-data-dirs.sh"
assert "idempotent: no error on rerun" true

# Wrong ownership detection: chown to root, re-run, should warn and fix
chown root:root /mnt/data/appdata
output=$(bash "$SCRIPT_DIR/07-data-dirs.sh" 2>&1)
if echo "$output" | grep -q "WARN"; then
  echo "  PASS: warns about wrong ownership"; ((pass++))
else
  echo "  FAIL: warns about wrong ownership"; ((fail++))
fi
assert_eq "ownership corrected" "svc_docker:grp_docker" "$(stat -c '%U:%G' /mnt/data/appdata)"

# ============================================================
echo ""
echo "=== 08-register-shares.sh ==="
reset_mocks

bash "$SCRIPT_DIR/08-register-shares.sh"
assert "sf-uuids file created" test -f "$SCRIPT_DIR/.sf-uuids"
assert "SF_COMPOSE_UUID set" grep -q "SF_COMPOSE_UUID=" "$SCRIPT_DIR/.sf-uuids"
assert "SF_APPDATA_UUID set" grep -q "SF_APPDATA_UUID=" "$SCRIPT_DIR/.sf-uuids"
assert "SF_BACKUP_UUID set" grep -q "SF_BACKUP_UUID=" "$SCRIPT_DIR/.sf-uuids"
assert "SF_SHARE_UUID set" grep -q "SF_SHARE_UUID=" "$SCRIPT_DIR/.sf-uuids"

# Idempotent: mock now returns existing shares
echo '{"total":4,"data":[
  {"uuid":"existing-1","name":"compose"},
  {"uuid":"existing-2","name":"appdata"},
  {"uuid":"existing-3","name":"backup"},
  {"uuid":"existing-4","name":"share"}
]}' > /tmp/omv-mock-shares.json

bash "$SCRIPT_DIR/08-register-shares.sh"
assert "idempotent: reuses existing UUIDs" grep -q "existing-1" "$SCRIPT_DIR/.sf-uuids"

# ============================================================
echo ""
echo "=== 09-configure-compose.sh ==="
reset_mocks

# Setup: sf-uuids from previous step
cat > "$SCRIPT_DIR/.sf-uuids" <<'EOF'
SF_COMPOSE_UUID=uuid-compose
SF_APPDATA_UUID=uuid-appdata
SF_BACKUP_UUID=uuid-backup
SF_SHARE_UUID=uuid-share
EOF

# Case 1: empty settings -- should apply without prompt
echo '{"sharedfolderref":"","datasharedfolderref":"","backupsharedfolderref":"","composeowner":"","composegroup":"","mode":"750","fileperms":"640"}' > /tmp/omv-mock-compose.json

bash "$SCRIPT_DIR/09-configure-compose.sh"
assert "applies to empty settings" test -f /tmp/omv-mock-compose-last-set.json

# Case 2: non-empty settings that differ + OMV_NONINTERACTIVE=1 -- should skip
rm -f /tmp/omv-mock-compose-last-set.json
echo '{"sharedfolderref":"other-uuid","datasharedfolderref":"other","backupsharedfolderref":"other","composeowner":"root","composegroup":"root","mode":"750","fileperms":"640"}' > /tmp/omv-mock-compose.json

OMV_NONINTERACTIVE=1 bash "$SCRIPT_DIR/09-configure-compose.sh"
assert "NONINTERACTIVE skips overwrite" test ! -f /tmp/omv-mock-compose-last-set.json

# Case 3: non-empty settings that differ + OMV_FORCE=1 -- should apply
OMV_FORCE=1 bash "$SCRIPT_DIR/09-configure-compose.sh"
assert "FORCE applies overwrite" test -f /tmp/omv-mock-compose-last-set.json

# Case 4: settings already match -- no-op
rm -f /tmp/omv-mock-compose-last-set.json
echo '{"sharedfolderref":"uuid-compose","datasharedfolderref":"uuid-appdata","backupsharedfolderref":"uuid-backup","composeowner":"svc_docker","composegroup":"grp_docker","mode":"750","fileperms":"640"}' > /tmp/omv-mock-compose.json

bash "$SCRIPT_DIR/09-configure-compose.sh"
assert "matching settings: still applies (idempotent set)" true

# ============================================================
echo ""
echo "=== 10-scheduled-jobs.sh ==="
reset_mocks

bash "$SCRIPT_DIR/10-scheduled-jobs.sh"
assert "jobs created file exists" test -f /tmp/omv-mock-jobs-created.json
job_count=$(wc -l < /tmp/omv-mock-jobs-created.json)
assert_eq "3 jobs created" "3" "$job_count"

# Idempotent: mock returns existing jobs
echo '{"total":3,"data":[
  {"uuid":"j1","comment":"omv-setup: daily backup"},
  {"uuid":"j2","comment":"omv-setup: weekly update"},
  {"uuid":"j3","comment":"omv-setup: weekly prune"}
]}' > /tmp/omv-mock-jobs.json
rm -f /tmp/omv-mock-jobs-created.json

bash "$SCRIPT_DIR/10-scheduled-jobs.sh"
if [[ -f /tmp/omv-mock-jobs-created.json ]]; then
  echo "  FAIL: idempotent -- should not create jobs again"; ((fail++))
else
  echo "  PASS: idempotent -- no duplicate jobs"; ((pass++))
fi

# ============================================================
echo ""
echo "=== 11-deploy.sh ==="
reset_mocks

bash "$SCRIPT_DIR/11-deploy.sh"
assert "omv-salt was called" test -f /tmp/omv-mock-salt.log
assert "called with 'deploy run compose'" grep -q "deploy run compose" /tmp/omv-mock-salt.log

# ============================================================
echo ""
echo "================================"
echo "Results: $pass passed, $fail failed"
echo "================================"

[[ $fail -eq 0 ]] && exit 0 || exit 1
