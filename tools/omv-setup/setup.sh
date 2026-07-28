#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# If piped via curl, download all scripts first
if [[ ! -f "$DIR/common.sh" ]]; then
  REPO="https://raw.githubusercontent.com/sdthach/openmediavault-compose/master/tools/omv-setup"
  DIR="/tmp/omv-setup-$$"
  mkdir -p "$DIR"
  for f in common.sh 01-groups.sh 02-service-user.sh 03-calling-user.sh \
           04-install-omv-extras.sh 05-install-omv-compose.sh 06-install-docker.sh \
           07-data-dirs.sh 08-register-shares.sh 09-configure-compose.sh \
           10-scheduled-jobs.sh 11-deploy.sh; do
    curl -sfL "$REPO/$f" -o "$DIR/$f"
  done
  trap "rm -rf $DIR" EXIT
fi

source "$DIR/common.sh"
need_root

log "Starting OMV Docker setup"
log "  SVC_USER=$SVC_USER  SVC_GROUP=$SVC_GROUP  DOCKER_GROUP=$DOCKER_GROUP"
log "  DATA_ROOT=$DATA_ROOT  CALLING_USER=$CALLING_USER"
echo ""

for script in "$DIR"/[0-9][0-9]-*.sh; do
  echo "=== $(basename "$script") ==="
  bash "$script"
  echo ""
done

log "Setup complete"
