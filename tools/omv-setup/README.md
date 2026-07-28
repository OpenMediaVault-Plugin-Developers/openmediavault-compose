# OMV Docker Setup

Idempotent setup scripts for OpenMediaVault + Docker + Compose. Automates what
you'd otherwise click through in the OMV web UI.

## What it does

1. Creates groups (`grp_docker` for data ownership, system `docker` for socket access)
2. Creates a service account (`svc_docker`) in both groups
3. Adds the calling user to both groups
4. Installs omv-extras, omv-compose, and Docker CE (via OMV's salt states)
5. Creates data directories at `/mnt/data/{appdata,compose,backup,share}`
6. Registers them as OMV shared folders (visible in the UI)
7. Configures the compose plugin (owner, group, shared folder assignments)
8. Creates scheduled jobs (daily backup, weekly update, weekly prune)
9. Deploys all config via `omv-salt`

## Usage

```bash
# Full setup -- clone and run
git clone https://github.com/sdthach/openmediavault-compose /tmp/omv-compose
sudo bash /tmp/omv-compose/tools/omv-setup/setup.sh

# Or curl the orchestrator (downloads all scripts)
curl -sL https://raw.githubusercontent.com/sdthach/openmediavault-compose/master/tools/omv-setup/setup.sh | sudo bash

# Run a single step
sudo bash tools/omv-setup/07-data-dirs.sh
```

## Configuration

Override defaults via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `OMV_SVC_USER` | `svc_docker` | Service account name |
| `OMV_SVC_GROUP` | `grp_docker` | Organizational group for data dirs |
| `OMV_DATA_ROOT` | `/mnt/data` | Root path for data directories |
| `OMV_NONINTERACTIVE` | unset | Set to `1` to skip overwrite prompts (safe: skips changes) |
| `OMV_FORCE` | unset | Set to `1` to apply all changes without prompting |

Example:

```bash
OMV_SVC_USER=svc_media OMV_SVC_GROUP=grp_media OMV_DATA_ROOT=/srv/docker sudo bash setup.sh
```

## Naming convention

| Prefix | Use | Examples |
|--------|-----|----------|
| `svc_` | Service accounts (non-interactive) | `svc_docker`, `svc_backup` |
| `grp_` | Permission groups | `grp_docker`, `grp_developers` |
| `app_` | Application-specific groups | `app_nginx`, `app_confluence` |
| `team_` | Team-scoped groups | `team_devops` |

## Script order

| # | Script | What it does |
|---|--------|--------------|
| 01 | `01-groups.sh` | Create `grp_docker` + system `docker` group |
| 02 | `02-service-user.sh` | Create `svc_docker` (primary: grp_docker, supplementary: docker) |
| 03 | `03-calling-user.sh` | Add SSH caller to both groups |
| 04 | `04-install-omv-extras.sh` | Install omv-extras plugin |
| 05 | `05-install-omv-compose.sh` | Install openmediavault-compose package |
| 06 | `06-install-docker.sh` | Install Docker via `omv-salt deploy run compose` |
| 07 | `07-data-dirs.sh` | Create data dirs, enforce ownership |
| 08 | `08-register-shares.sh` | Register dirs as OMV shared folders |
| 09 | `09-configure-compose.sh` | Set compose plugin settings |
| 10 | `10-scheduled-jobs.sh` | Create backup/update/prune cron jobs |
| 11 | `11-deploy.sh` | Apply all config via salt |

## Safety

- **Idempotent**: re-run anytime. Each script checks state before acting.
- **Non-destructive**: existing settings prompt before overwrite (unless `OMV_FORCE=1`).
- **Ownership enforcement**: dirs always get corrected ownership, with a warning if changed.
- **OMV-native**: all config goes through `omv-rpc` (same API as the web UI). Nothing bypassed.

## Requirements

- OpenMediaVault 7.x installed
- Root access (sudo)
- Network access (for package downloads)
- A mounted filesystem at `DATA_ROOT` already registered in OMV
