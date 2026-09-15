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

SLOTS="${SLOTS:-4}"                 # one slot per core; CI is mostly IO-bound
BASE_DIR="${BASE_DIR:-/opt/gh-runner}"
ORG_NAME="${ORG_NAME:-MabrokaMedia}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,linux,arm64,fast,stable}"

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

echo "==> dependencies"
# The EC2 fleet ran a baked AMI on Amazon Linux, which supplied a C toolchain
# and the AWS CLI in its base image. A stock Ubuntu image does not, and their
# absence does not read as a missing package: Rust jobs fail with
# "linker `cc` not found", and the S3 cache action dies on "aws: command not
# found" mid-pipe instead of degrading to a cache miss. Both cost a red build.
if command -v dnf >/dev/null 2>&1; then
  dnf install -y git jq libicu tar gzip zstd curl unzip zip                  gcc gcc-c++ make lld pkgconfig openssl-devel
  # Docker is optional: only workflows using container jobs or services need it.
  dnf install -y docker || dnf install -y podman-docker || true
  systemctl enable --now docker 2>/dev/null || true
else
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  # build-essential provides `cc`; lld matches the AMI, which added it because
  # linking dominates large release builds.
  apt-get install -y git jq tar gzip zstd curl unzip zip ca-certificates                      build-essential lld pkg-config libssl-dev
  apt-get install -y libicu-dev || true
  apt-get install -y docker.io || true
  systemctl enable --now docker 2>/dev/null || true
fi

# AWS CLI v2. Still required after the move, because the rust-s3-cache
# composite actions shell out to it.
if ! command -v aws >/dev/null 2>&1; then
  echo "==> aws cli"
  tmp=$(mktemp -d)
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "$tmp/awscli.zip"
  unzip -q "$tmp/awscli.zip" -d "$tmp"
  "$tmp/aws/install" --update >/dev/null
  rm -rf "$tmp"
fi
echo "    cc=$(command -v cc || echo MISSING)  aws=$(command -v aws || echo MISSING)"

echo "==> runner user"
id runner >/dev/null 2>&1 || useradd -m -s /bin/bash runner
getent group docker >/dev/null 2>&1 && usermod -aG docker runner || true

echo "==> config"
# root:runner, not root:root. The units run as `runner`, so root-only files
# leave the loop unable to read its own configuration or the token, and it
# exits before registering.
install -d -m 0750 -o root -g runner /etc/gh-runner
if [ ! -s /etc/gh-runner/pat ]; then
  cat >&2 <<'MSG'

  /etc/gh-runner/pat is missing.

  Put a GitHub PAT with org runner admin rights there, then re-run:

      printf '%s' 'ghp_xxx' > /etc/gh-runner/pat

  provision.sh fixes its ownership and mode; it does not need to be readable
  by anyone but root before you run it.

  This is the same token the EC2 fleet reads from SSM /gh-runner/github-pat.
MSG
  exit 1
fi
chown root:runner /etc/gh-runner/pat
chmod 640 /etc/gh-runner/pat
cat > /etc/gh-runner/runner.env <<ENV
ORG_NAME=${ORG_NAME}
RUNNER_LABELS=${RUNNER_LABELS}
BASE_DIR=${BASE_DIR}
PAT_FILE=/etc/gh-runner/pat
ENV
chown root:runner /etc/gh-runner/runner.env
chmod 640 /etc/gh-runner/runner.env

# Shared build cache. rust-s3-cache's `disk` backend writes here instead of to
# the S3 bucket in us-east-2, which is faster (the archive never leaves the
# machine) and survives the AWS account going away. Shared across slots on
# purpose: a cache warmed by one job should serve the next, whichever slot
# takes it.
echo "==> build cache"
install -d -m 0775 -o runner -g runner "${CACHE_DIR:-/opt/gh-runner/cache}"

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

  # ── Per-slot CARGO_HOME / RUSTUP_HOME ────────────────────────────────
  # Every slot runs as the same `runner` user with the same $HOME, so all
  # four resolved CARGO_HOME to /home/runner/.cargo and RUSTUP_HOME to
  # /home/runner/.rustup. One directory, four concurrent writers. That is a
  # single root cause with two faces, both seen on 2026-09-15:
  #
  #   * `rustc: command not found` then `/home/runner/.cargo/bin/rustc:
  #     Text file busy` (exit 126) in *Install Rust*, when two slots run
  #     dtolnay/rust-toolchain at the same moment and one rewrites a rustup
  #     proxy while the other execs it.
  #     davoxi-promo-exchange-business run 34970476795.
  #   * the rust-s3-cache save tarring ~/.cargo/registry while another
  #     slot's cargo writes into it, so tar exits non-zero.
  #     davoxi-promo-exchange-business run 35020627148 lost a whole deploy.
  #
  # Neither is a transport flake and neither involves S3 (the cache backend
  # resolves to `disk` here). Retrying just re-rolls the dice: the race
  # fires whenever two Rust jobs overlap, which is the normal state of a
  # four-slot host.
  #
  # The Actions runner reads `.env` from its own directory and applies it to
  # every job, and dtolnay/rust-toolchain does
  # `CARGO_HOME=${CARGO_HOME:-$HOME/.cargo} >> $GITHUB_ENV`, i.e. it honours
  # an inherited value. So setting them here reaches every step of every job
  # with no workflow changes in any consumer repo.
  #
  # Written every run so re-provisioning repairs a hand-edited file, and
  # LANG is preserved because Rust jobs emit UTF-8 diagnostics.
  #
  # Cost: each slot keeps its own registry and toolchains instead of sharing
  # one copy. Budget for it — see oracle/README.md. The slots pick the new
  # values up on their next ephemeral restart, so no running job is
  # disturbed and no manual restart is needed.
  install -d -o runner -g runner "$d/.cargo" "$d/.rustup"
  cat > "$d/.env" <<SLOTENV
LANG=C.UTF-8
CARGO_HOME=$d/.cargo
RUSTUP_HOME=$d/.rustup
SLOTENV
  chown runner:runner "$d/.env"
  chmod 644 "$d/.env"
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
