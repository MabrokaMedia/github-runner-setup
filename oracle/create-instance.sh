#!/usr/bin/env bash
# Create the Oracle Always Free ARM runner host, retrying until Oracle has
# capacity. Free A1 capacity is often exhausted ("Out of host capacity"); it
# frees up at random, so this tries every availability domain, waits, and
# tries again until one launch succeeds.
#
# Needs the OCI CLI with an API key (~/.oci/config):
#   oci setup config        # then add the printed public key in the console:
#                           # Profile > Tokens and keys > Add API key
#
#   ./oracle/create-instance.sh                  # defaults below
#   INTERVAL=120 MAX_HOURS=48 ./oracle/create-instance.sh
#
# Safe to re-run: it stops at once if an instance with NAME already exists.
# Free limits as of 2026-11-08: 2 OCPUs, 12 GB memory, 200 GB of disk in total.
set -euo pipefail

NAME="${NAME:-gh-runner-oracle-2}"
OCPUS="${OCPUS:-2}"
MEMORY_GB="${MEMORY_GB:-12}"
BOOT_GB="${BOOT_GB:-100}"
SHAPE="${SHAPE:-VM.Standard.A1.Flex}"
SUBNET_NAME="${SUBNET_NAME:-gh-sub}"
SSH_KEY_FILE="${SSH_KEY_FILE:-$HOME/.ssh/oracle_gh_runner.pub}"
INTERVAL="${INTERVAL:-300}"        # seconds between rounds
MAX_HOURS="${MAX_HOURS:-72}"
PROFILE="${OCI_PROFILE:-DEFAULT}"

oci_() { oci --profile "$PROFILE" "$@"; }
log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }

command -v oci >/dev/null || { echo "oci CLI not found" >&2; exit 1; }
[ -s "$SSH_KEY_FILE" ] || { echo "SSH public key not found: $SSH_KEY_FILE" >&2; exit 1; }

CONFIG="${OCI_CLI_CONFIG_FILE:-$HOME/.oci/config}"
TENANCY="${COMPARTMENT_ID:-$(awk -F= -v p="[$PROFILE]" '$0==p{f=1;next} /^\[/{f=0} f&&$1~/^tenancy/{gsub(/ /,"",$2);print $2;exit}' "$CONFIG")}"
[ -n "$TENANCY" ] || { echo "no tenancy in $CONFIG for profile $PROFILE" >&2; exit 1; }

existing="$(oci_ compute instance list --compartment-id "$TENANCY" --display-name "$NAME" \
  --query 'data[?"lifecycle-state"!=`TERMINATED` && "lifecycle-state"!=`TERMINATING`].id | [0]' --raw-output 2>/dev/null || true)"
if [ -n "$existing" ] && [ "$existing" != "null" ]; then
  log "$NAME already exists: $existing"; exit 0
fi

SUBNET_ID="$(oci_ network subnet list --compartment-id "$TENANCY" --display-name "$SUBNET_NAME" \
  --query 'data[0].id' --raw-output)"
[ -n "$SUBNET_ID" ] && [ "$SUBNET_ID" != "null" ] || { echo "subnet $SUBNET_NAME not found" >&2; exit 1; }

IMAGE_ID="$(oci_ compute image list --compartment-id "$TENANCY" --operating-system "Oracle Linux" \
  --operating-system-version 9 --shape "$SHAPE" --sort-by TIMECREATED --sort-order DESC \
  --query 'data[0].id' --raw-output)"
[ -n "$IMAGE_ID" ] && [ "$IMAGE_ID" != "null" ] || { echo "no Oracle Linux 9 image for $SHAPE" >&2; exit 1; }

mapfile -t ADS < <(oci_ iam availability-domain list --compartment-id "$TENANCY" --query 'data[].name' --raw-output | tr -d '[]", ' | grep -v '^$')
[ "${#ADS[@]}" -gt 0 ] || { echo "no availability domains" >&2; exit 1; }

log "creating $NAME: $SHAPE ${OCPUS} OCPU / ${MEMORY_GB} GB, ${BOOT_GB} GB disk, subnet $SUBNET_NAME"
log "availability domains: ${ADS[*]}; retrying every ${INTERVAL}s for up to ${MAX_HOURS}h"

deadline=$(( $(date +%s) + MAX_HOURS * 3600 ))
round=0
while [ "$(date +%s)" -lt "$deadline" ]; do
  round=$((round + 1))
  for ad in "${ADS[@]}"; do
    out="$(oci_ compute instance launch \
      --compartment-id "$TENANCY" --availability-domain "$ad" --display-name "$NAME" \
      --shape "$SHAPE" --shape-config "{\"ocpus\": $OCPUS, \"memoryInGBs\": $MEMORY_GB}" \
      --image-id "$IMAGE_ID" --subnet-id "$SUBNET_ID" --assign-public-ip true \
      --boot-volume-size-in-gbs "$BOOT_GB" --ssh-authorized-keys-file "$SSH_KEY_FILE" \
      --query 'data.id' --raw-output 2>&1)" && {
        log "launched in $ad: $out"
        log "waiting for RUNNING..."
        oci_ compute instance get --instance-id "$out" --wait-for-state RUNNING --max-wait-seconds 900 >/dev/null
        ip="$(oci_ compute instance list-vnics --instance-id "$out" --query 'data[0]."public-ip"' --raw-output)"
        log "$NAME is RUNNING. Public IP: $ip"
        log "next: ssh -i ~/.ssh/oracle_gh_runner opc@$ip, then run provision.sh"
        exit 0
      }
    case "$out" in
      *"ut of host capacity"*|*"ut of capacity"*) log "round $round: $ad full" ;;
      *TooManyRequests*|*"429"*) log "round $round: rate limited, slowing down"; sleep 60 ;;
      *LimitExceeded*|*"limit"*) log "$ad: service limit reached (is the old instance still there?)"; echo "$out" | tail -3 >&2 ;;
      *) log "$ad: unexpected error:"; echo "$out" | tail -5 >&2 ;;
    esac
  done
  sleep "$INTERVAL"
done
log "gave up after ${MAX_HOURS}h without capacity"
exit 1
