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
