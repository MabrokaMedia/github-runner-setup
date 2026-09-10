#!/usr/bin/env bash
# Provision an Oracle Cloud ARM instance as a GitHub Actions runner host.
# Idempotent: safe to re-run to change the slot count or update the runner.
#
# This does NOT touch AWS. The EC2 fleet keeps working, and because the
# runners here register with the SAME labels, no workflow file changes.
# See oracle/README.md for how to switch between the two.
#
#   sudo ./provision.sh
set -euo pipefail

SLOTS="${SLOTS:-3}"                 # leave a core for the OS on a 4-core box
BASE_DIR="${BASE_DIR:-/opt/gh-runner}"
ORG_NAME="${ORG_NAME:-MabrokaMedia}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,linux,arm64,fast,stable}"

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

echo "==> dependencies"
# Oracle Linux ships dnf, Ubuntu images ship apt; support both.
if command -v dnf >/dev/null 2>&1; then
  dnf install -y git jq libicu tar gzip zstd curl
  # Docker is optional: only workflows using container jobs or services need it.
  dnf install -y docker || dnf install -y podman-docker || true
  systemctl enable --now docker 2>/dev/null || true
else
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y git jq libicu[0-9]* tar gzip zstd curl ca-certificates || \
    apt-get install -y git jq tar gzip zstd curl ca-certificates
  apt-get install -y docker.io || true
  systemctl enable --now docker 2>/dev/null || true
fi

echo "==> runner user"
id runner >/dev/null 2>&1 || useradd -m -s /bin/bash runner
getent group docker >/dev/null 2>&1 && usermod -aG docker runner || true

echo "==> config"
install -d -m 0750 /etc/gh-runner
if [ ! -s /etc/gh-runner/pat ]; then
  cat >&2 <<'MSG'

  /etc/gh-runner/pat is missing.

  Put a GitHub PAT with org runner admin rights there, then re-run:

      printf '%s' 'ghp_xxx' > /etc/gh-runner/pat
      chmod 600 /etc/gh-runner/pat

  This is the same token the EC2 fleet reads from SSM /gh-runner/github-pat.
MSG
  exit 1
fi
chmod 600 /etc/gh-runner/pat
cat > /etc/gh-runner/runner.env <<ENV
ORG_NAME=${ORG_NAME}
RUNNER_LABELS=${RUNNER_LABELS}
BASE_DIR=${BASE_DIR}
PAT_FILE=/etc/gh-runner/pat
ENV
chmod 640 /etc/gh-runner/runner.env

echo "==> runner binaries"
install -d -o runner -g runner "$BASE_DIR"
install -m 0755 -o runner -g runner "$(dirname "$0")/runner-loop.sh" "$BASE_DIR/runner-loop.sh"

VERSION="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | jq -r .tag_name | tr -d v)"
TARBALL="actions-runner-linux-arm64-${VERSION}.tar.gz"
if [ ! -f "$BASE_DIR/$TARBALL" ]; then
  curl -fsSL -o "$BASE_DIR/$TARBALL" \
    "https://github.com/actions/runner/releases/download/v${VERSION}/${TARBALL}"
fi
echo "    runner v${VERSION}"

for i in $(seq 1 "$SLOTS"); do
  d="$BASE_DIR/slot-$i"
  if [ ! -x "$d/run.sh" ]; then
    install -d -o runner -g runner "$d"
    tar xzf "$BASE_DIR/$TARBALL" -C "$d"
    chown -R runner:runner "$d"
  fi
done
chown -R runner:runner "$BASE_DIR"

echo "==> systemd"
install -m 0644 "$(dirname "$0")/gh-runner@.service" /etc/systemd/system/gh-runner@.service
systemctl daemon-reload
for i in $(seq 1 "$SLOTS"); do systemctl enable --now "gh-runner@$i"; done

# Slots above the requested count are stopped so lowering SLOTS actually shrinks.
for unit in $(systemctl list-units --plain --no-legend 'gh-runner@*' | awk '{print $1}'); do
  n="${unit#gh-runner@}"; n="${n%.service}"
  [ "$n" -gt "$SLOTS" ] && systemctl disable --now "$unit" || true
done

echo
echo "==> $SLOTS slot(s) up. Labels: $RUNNER_LABELS"
echo "    systemctl status 'gh-runner@*'"
echo "    https://github.com/organizations/${ORG_NAME}/settings/actions/runners"
