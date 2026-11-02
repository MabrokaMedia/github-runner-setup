#!/usr/bin/env bash
# One ephemeral runner slot. systemd restarts this after every job, so each
# job gets a freshly registered runner exactly as it does on the EC2 fleet,
# where the whole instance was replaced instead.
#
# The registration token is short-lived (~1h) and single-use, so it is fetched
# on every loop rather than baked into the unit.
set -euo pipefail

SLOT="${1:?usage: runner-loop.sh <slot-number>}"
CONF=/etc/gh-runner/runner.env
# Fail loudly rather than silently skipping: an unreadable config used to
# surface as "ORG_NAME missing", which points at the file's contents when the
# real fault is its permissions.
if [ ! -r "$CONF" ]; then
  echo "cannot read $CONF as $(id -un) — check it is root:runner mode 640" >&2
  exit 1
fi
# shellcheck source=/dev/null
. "$CONF"

ORG_NAME="${ORG_NAME:?ORG_NAME missing from $CONF}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,linux,arm64,fast,stable}"
RUNNER_GROUP="${RUNNER_GROUP:-Default}"
BASE_DIR="${BASE_DIR:-/opt/gh-runner}"
PAT_FILE="${PAT_FILE:-/etc/gh-runner/pat}"

HOME_DIR="${BASE_DIR}/slot-${SLOT}"
cd "$HOME_DIR"

# Reclaim this slot's old job directories before taking work, but only under
# pressure. They hold the previous job's checkout and its incremental build,
# which is worth keeping while there is room for it - and worth nothing at all
# once the disk is full. A full disk does not fail a job cleanly: the runner
# dies before the first step with "No space left on device" while trying to
# write its own log, so the job shows as failed with nothing to read. That is
# what happened on 2026-09-13, with 61 GB of stale workspaces across four
# slots and every self-hosted job failing on arrival.
#
# Only this slot is touched. Another slot may be mid-job, and its _work is
# where that job lives; with four slots cycling, each cleans itself as it
# picks up work, which converges without ever reaching into a running job.
#
# The floor is 50G because parlo-seo's full rebuild refuses to start below 45G
# free, and at 20G it never got there: on 2026-11-02 the disk sat at 35-45G
# free with 37G of it in shared-cache entries nobody had read for a week.
FREE_FLOOR_GB="${FREE_FLOOR_GB:-50}"
CACHE_DIR="${CACHE_DIR:-${BASE_DIR}/cache}"
free_gb() { df -BG --output=avail / | tail -1 | tr -dc '0-9'; }
if [ "$(free_gb)" -lt "$FREE_FLOOR_GB" ]; then
  # Dead weight first: shared-cache entries unread for a week (relatime keeps
  # atime to within a day), and docker images, volumes and build cache that no
  # container uses. A running build's files are fresh, so neither touches one.
  echo "slot ${SLOT}: $(free_gb)G free, below ${FREE_FLOOR_GB}G - pruning stale caches"
  find "$CACHE_DIR" -type f -atime +7 -delete 2>/dev/null || true
  if command -v docker >/dev/null 2>&1; then
    docker image prune -af --filter until=168h >/dev/null 2>&1 || true
    docker volume prune -af >/dev/null 2>&1 || true
    docker builder prune -af --filter until=168h >/dev/null 2>&1 || true
  fi
  echo "slot ${SLOT}: $(free_gb)G free after pruning"
fi
if [ "$(free_gb)" -lt "$FREE_FLOOR_GB" ]; then
  echo "slot ${SLOT}: $(free_gb)G free, below ${FREE_FLOOR_GB}G - clearing this slot's job directories"
  # _actions, _tool, _temp and _PipelineMapping are the runner's own caches:
  # small, and slow to rebuild. Only the per-repository directories go.
  find "${HOME_DIR}/_work" -mindepth 1 -maxdepth 1 -type d ! -name '_*' -exec rm -rf {} + 2>/dev/null || true
  echo "slot ${SLOT}: $(free_gb)G free after"
fi

GH_PAT="$(cat "$PAT_FILE")"

# A previous run may have exited mid-job (reboot, OOM). GitHub still holds a
# registration for this name, and re-registering the same name fails, so drop
# the old one first. Best effort: a token that no longer works is not fatal.
if [ -f .runner ]; then
  REMOVE_TOKEN="$(curl -fsS -X POST \
    -H "Authorization: token ${GH_PAT}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/orgs/${ORG_NAME}/actions/runners/remove-token" | jq -r .token)" || REMOVE_TOKEN=""
  [ -n "$REMOVE_TOKEN" ] && ./config.sh remove --token "$REMOVE_TOKEN" >/dev/null 2>&1 || true
fi

REG_TOKEN="$(curl -fsS -X POST \
  -H "Authorization: token ${GH_PAT}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/orgs/${ORG_NAME}/actions/runners/registration-token" | jq -r .token)"

if [ -z "$REG_TOKEN" ] || [ "$REG_TOKEN" = "null" ]; then
  echo "could not obtain a registration token for org ${ORG_NAME}" >&2
  exit 1
fi

./config.sh \
  --url "https://github.com/${ORG_NAME}" \
  --token "$REG_TOKEN" \
  --name "oracle-$(hostname -s)-${SLOT}" \
  --labels "$RUNNER_LABELS" \
  --runnergroup "$RUNNER_GROUP" \
  --work _work \
  --ephemeral \
  --unattended \
  --replace

# Runs exactly one job, then exits 0. systemd brings the slot straight back.
exec ./run.sh
