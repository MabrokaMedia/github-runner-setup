#!/bin/bash
set -euo pipefail

# Disable MSYS2/Git-Bash POSIX→Windows path translation. On Windows, Git-Bash
# rewrites any CLI argument starting with `/` to a Windows path before the
# child process sees it — so passing `WEBHOOK_SECRET_PARAM=/gh-runner/webhook-secret`
# to the Windows AWS CLI silently became `WEBHOOK_SECRET_PARAM=C:/Program Files/Git/gh-runner/webhook-secret`,
# which broke every webhook for ~10h on 2026-04-30. Belt and braces: also
# export MSYS2_ARG_CONV_EXCL='*' so any env shorthand we build never triggers
# the conversion. Both vars are no-ops on Linux/macOS.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

# =============================================================================
# Add a third runner tier: gh-runner-stable-asg (100% on-demand)
# =============================================================================
# Why:
#   The fast ASG is 100% spot. Long-running jobs (cargo lambda
#   build, serverless deploy) routinely run 20-30 min and get reclaimed mid-
#   flight when the spot pool churns. The fix isn't more diversification —
#   c7g/c6g/m6g/m7g already covers four pools — it's an on-demand fallback
#   for jobs whose cancellation cost exceeds the 5x price premium.
#
#   This script provisions:
#     - gh-runner-stable-lt        (launch template, on-demand, c7g.2xlarge)
#     - gh-runner-stable-asg       (min=0, max=10, scale-to-zero)
#     - CapacityRebalance enabled on gh-runner-asg (free, helps recovery)
#     - Lambda env updated with STABLE_ASG_NAME
#
# Usage:
#   AWS_REGION=us-east-1 bash add-stable-asg.sh                 # provision + cheap sanity check
#   AWS_REGION=us-east-1 bash add-stable-asg.sh --smoke-test    # also do a launch-based smoke test
#
# Idempotent: re-running updates the launch template + ASG min/max + Lambda
# env, never duplicates resources.
# =============================================================================

AWS_REGION="${AWS_REGION:-us-east-1}"
PREFIX="gh-runner"
FAST_ASG="${PREFIX}-asg"
FAST_LT="${PREFIX}-lt"
STABLE_ASG="${PREFIX}-stable-asg"
STABLE_LT="${PREFIX}-stable-lt"
LAMBDA_NAME="${PREFIX}-scaler"
MAX_RUNNERS="${MAX_RUNNERS:-10}"

# Parse flags
SMOKE_TEST=0
for arg in "$@"; do
    case "$arg" in
        --smoke-test) SMOKE_TEST=1 ;;
        --help|-h)
            sed -n '14,35p' "$0"
            exit 0
            ;;
        *) echo "Unknown flag: $arg" >&2; exit 2 ;;
    esac
done

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }

command -v aws >/dev/null || err "AWS CLI not found"
command -v jq  >/dev/null || err "jq not found"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
log "AWS Account: $ACCOUNT_ID | Region: $AWS_REGION"

# ─── STEP 1: Read fast LT to mirror its config ──────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo " STEP 1: Read fast launch template (mirror config)"
echo "═══════════════════════════════════════════════════════════════"

# Source the LT version the FAST ASG is actually running, not `$Latest`.
# Reason: on 2026-05-01 the prod fast ASG was pinned to v18 (working AMI
# `ami-028f3f080eda659c5`, runner binary pre-baked at /home/runner) while
# v19 was a half-baked AMI upgrade (`ami-0dd9b3d287933ff67` — runner not
# installed) that nobody promoted. Pulling `$Latest` got v19, which made
# every stable-tier launch register-fail and die at the 5-min watchdog
# without ever picking up the queued job. The fast ASG is the ground
# truth — whatever AMI/user-data IT runs is the one that's known-good.
FAST_LT_VERSION=$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$FAST_ASG" \
    --region "$AWS_REGION" \
    --query 'AutoScalingGroups[0].MixedInstancesPolicy.LaunchTemplate.LaunchTemplateSpecification.Version
             || AutoScalingGroups[0].LaunchTemplate.Version' \
    --output text)
[[ -z "$FAST_LT_VERSION" || "$FAST_LT_VERSION" == "None" ]] && err "Could not read fast ASG's LT version — is gh-runner-asg provisioned?"
log "Sourcing from fast LT version $FAST_LT_VERSION (the version the live fast ASG actually uses)"

FAST_LT_DATA=$(aws ec2 describe-launch-template-versions \
    --launch-template-name "$FAST_LT" \
    --versions "$FAST_LT_VERSION" \
    --region "$AWS_REGION" \
    --query 'LaunchTemplateVersions[0].LaunchTemplateData' \
    --output json) || err "Fast LT $FAST_LT version $FAST_LT_VERSION not found"

# Re-label the user-data: the fast LT bakes `--labels …,fast` into config.sh
# at instance boot. Cloning the user-data verbatim would make new stable-ASG
# instances register as `fast` runners and pick up fast jobs — defeating the
# routing. Decode → sed swap → re-encode.
FAST_USER_DATA=$(echo "$FAST_LT_DATA" | jq -r '.UserData' | tr -d '\r' | base64 -d)
STABLE_USER_DATA=$(echo "$FAST_USER_DATA" | sed 's/--labels self-hosted,linux,arm64,fast/--labels self-hosted,linux,arm64,stable/')
if ! diff <(echo "$FAST_USER_DATA") <(echo "$STABLE_USER_DATA") >/dev/null; then
    log "Re-labeled user-data: fast → stable"
else
    err "Label swap didn't match — fast LT user-data may have changed shape. Inspect manually."
fi
STABLE_USER_DATA_B64=$(echo "$STABLE_USER_DATA" | base64 -w 0)

# Strip spot config + swap user-data; keep everything else (AMI, instance
# profile, SG, EBS, tags) byte-for-byte identical.
STABLE_LT_DATA=$(echo "$FAST_LT_DATA" \
    | jq --arg ud "$STABLE_USER_DATA_B64" 'del(.InstanceMarketOptions) | .UserData = $ud')
log "Mirrored fast LT, removed InstanceMarketOptions (becomes on-demand)"

# ─── STEP 2: Create or update stable launch template ────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo " STEP 2: Stable launch template"
echo "═══════════════════════════════════════════════════════════════"

# Use --query so AWS CLI exits 0 even when the LT doesn't exist (avoids
# pipefail killing the script on first run).
STABLE_LT_EXISTS=$(aws ec2 describe-launch-templates \
    --filters "Name=launch-template-name,Values=$STABLE_LT" \
    --region "$AWS_REGION" \
    --query 'LaunchTemplates | length(@)' \
    --output text)

if [[ "$STABLE_LT_EXISTS" -gt 0 ]]; then
    aws ec2 create-launch-template-version \
        --launch-template-name "$STABLE_LT" \
        --source-version '$Latest' \
        --launch-template-data "$STABLE_LT_DATA" \
        --region "$AWS_REGION" >/dev/null
    aws ec2 modify-launch-template \
        --launch-template-name "$STABLE_LT" \
        --default-version '$Latest' \
        --region "$AWS_REGION" >/dev/null
    warn "Updated launch template: $STABLE_LT (new \$Latest version)"
else
    aws ec2 create-launch-template \
        --launch-template-name "$STABLE_LT" \
        --launch-template-data "$STABLE_LT_DATA" \
        --region "$AWS_REGION" >/dev/null
    log "Created launch template: $STABLE_LT"
fi

# ─── STEP 3: Discover subnet from fast ASG ──────────────────────────────────
FAST_SUBNETS=$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$FAST_ASG" \
    --region "$AWS_REGION" \
    --query 'AutoScalingGroups[0].VPCZoneIdentifier' \
    --output text)
[[ -z "$FAST_SUBNETS" || "$FAST_SUBNETS" == "None" ]] && err "Fast ASG $FAST_ASG missing or has no subnets"
log "Reusing subnet(s) from fast ASG: $FAST_SUBNETS"

# ─── STEP 4: Create or update stable ASG ────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo " STEP 4: Stable ASG (100% on-demand, scale-to-zero)"
echo "═══════════════════════════════════════════════════════════════"

STABLE_ASG_EXISTS=$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$STABLE_ASG" \
    --query "AutoScalingGroups | length(@)" --output text \
    --region "$AWS_REGION")

if [[ "$STABLE_ASG_EXISTS" -gt 0 ]]; then
    aws autoscaling update-auto-scaling-group \
        --auto-scaling-group-name "$STABLE_ASG" \
        --launch-template "LaunchTemplateName=$STABLE_LT,Version=\$Latest" \
        --min-size 0 --max-size "$MAX_RUNNERS" \
        --region "$AWS_REGION"
    warn "Updated ASG: $STABLE_ASG (min=0, max=$MAX_RUNNERS)"
else
    aws autoscaling create-auto-scaling-group \
        --auto-scaling-group-name "$STABLE_ASG" \
        --launch-template "LaunchTemplateName=$STABLE_LT,Version=\$Latest" \
        --min-size 0 --max-size "$MAX_RUNNERS" --desired-capacity 0 \
        --vpc-zone-identifier "$FAST_SUBNETS" \
        --tags "Key=Name,Value=github-runner-stable,PropagateAtLaunch=true" \
               "Key=Tier,Value=stable,PropagateAtLaunch=true" \
        --region "$AWS_REGION"
    log "Created ASG: $STABLE_ASG (min=0, max=$MAX_RUNNERS, desired=0)"
fi

# Suspend AZ rebalancing — same rationale as the fast ASG (ephemeral
# runners, single-AZ on purpose, no value in cross-AZ shuffling).
aws autoscaling suspend-processes \
    --auto-scaling-group-name "$STABLE_ASG" \
    --scaling-processes AZRebalance \
    --region "$AWS_REGION"
log "Suspended AZRebalance on $STABLE_ASG"

# ─── STEP 5: Enable capacity rebalance on the spot ASGs ─────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo " STEP 5: Capacity rebalance (free; tightens spot recovery)"
echo "═══════════════════════════════════════════════════════════════"

# $FAST_ASG is the only spot ASG — the stable tier is on-demand, so capacity
# rebalance does not apply to it. This loop also covered "${PREFIX}-small-asg",
# an ASG that was never created in any account; see the note in scaler.py.
for asg in "$FAST_ASG"; do
    if aws autoscaling describe-auto-scaling-groups \
        --auto-scaling-group-names "$asg" \
        --region "$AWS_REGION" \
        --query 'AutoScalingGroups[0].AutoScalingGroupName' --output text 2>/dev/null \
        | grep -q "$asg"; then
        aws autoscaling update-auto-scaling-group \
            --auto-scaling-group-name "$asg" \
            --capacity-rebalance \
            --region "$AWS_REGION"
        log "Enabled CapacityRebalance on $asg"
    else
        warn "$asg not found; skipping"
    fi
done

# ─── STEP 6: Update Lambda env with STABLE_ASG_NAME ─────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo " STEP 6: Update scaler Lambda env"
echo "═══════════════════════════════════════════════════════════════"

CURRENT_ENV=$(aws lambda get-function-configuration \
    --function-name "$LAMBDA_NAME" \
    --region "$AWS_REGION" \
    --query 'Environment.Variables' \
    --output json) || err "Lambda $LAMBDA_NAME not found"

# Build the shorthand `Variables={K=v,K2=v2,...}` form. We avoid JSON-via-file
# because on Git-Bash/MSYS2 the native Windows AWS CLI can't read POSIX paths
# returned by mktemp. Shorthand is fine here — none of the values contain
# `,` or `=`. If a future env var does, switch to writing JSON to a Windows
# path (e.g. cygpath -w "$file") and use --environment file://<winpath>.
ENV_SHORTHAND=$(echo "$CURRENT_ENV" \
    | jq --arg v "$STABLE_ASG" -r '
        (. + {STABLE_ASG_NAME: $v})
        | to_entries
        | map("\(.key)=\(.value|tostring)")
        | join(",")
        | "Variables={" + . + "}"
    ')

aws lambda update-function-configuration \
    --function-name "$LAMBDA_NAME" \
    --environment "$ENV_SHORTHAND" \
    --region "$AWS_REGION" >/dev/null
log "Lambda $LAMBDA_NAME env updated: STABLE_ASG_NAME=$STABLE_ASG"

warn "NOTE: also deploy the updated lambda/scaler.py — env alone won't route the 'stable' label."
warn "      cd lambda && zip -j /tmp/scaler.zip scaler.py && \\"
warn "      aws lambda update-function-code --function-name $LAMBDA_NAME \\"
warn "        --zip-file fileb:///tmp/scaler.zip --region $AWS_REGION"

# ─── STEP 7: Sanity check (always runs, no instance launch) ─────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo " STEP 7: Sanity check (config integrity)"
echo "═══════════════════════════════════════════════════════════════"

# (1) AMI must match the one fast ASG actually runs. Catches the 2026-05-01
#     bug where this script sourced fast LT $Latest (broken AMI v19) instead
#     of the version the fast ASG was pinned to (working v18). PR #5 fixed
#     the source, this check guards the result.
EXPECTED_AMI=$(echo "$FAST_LT_DATA" | jq -r '.ImageId')
ACTUAL_AMI=$(aws ec2 describe-launch-template-versions \
    --launch-template-name "$STABLE_LT" \
    --versions '$Latest' \
    --region "$AWS_REGION" \
    --query 'LaunchTemplateVersions[0].LaunchTemplateData.ImageId' \
    --output text | tr -d '\r')
if [[ "$EXPECTED_AMI" != "$ACTUAL_AMI" ]]; then
    err "AMI mismatch — stable LT has $ACTUAL_AMI, fast ASG runs $EXPECTED_AMI"
fi
log "AMI matches fast ASG: $ACTUAL_AMI"

# (2) AMI must be in `available` state. Catches "AMI was deleted/deprecated
#     after the fast ASG was provisioned but before stable was added".
AMI_STATE=$(aws ec2 describe-images --image-ids "$ACTUAL_AMI" --region "$AWS_REGION" \
    --query 'Images[0].State' --output text 2>/dev/null || echo "missing")
if [[ "$AMI_STATE" != "available" ]]; then
    err "AMI $ACTUAL_AMI is in state '$AMI_STATE' (expected 'available'). New launches will fail."
fi
log "AMI is available"

# (3) User-data carries the `stable` label. Catches sed-substitution failure
#     (which would silently make stable instances register as fast runners).
STABLE_UD_VERIFY=$(aws ec2 describe-launch-template-versions \
    --launch-template-name "$STABLE_LT" \
    --versions '$Latest' \
    --region "$AWS_REGION" \
    --query 'LaunchTemplateVersions[0].LaunchTemplateData.UserData' \
    --output text | tr -d '\r' | base64 -d)
if ! echo "$STABLE_UD_VERIFY" | grep -q "labels self-hosted,linux,arm64,stable"; then
    err "user-data missing 'stable' label — sed swap failed. Inspect manually."
fi
if echo "$STABLE_UD_VERIFY" | grep -q "labels self-hosted,linux,arm64,fast"; then
    err "user-data still has 'fast' label after sed swap. Inspect manually."
fi
log "user-data carries 'stable' label only (no leftover 'fast')"

# ─── STEP 8: Optional launch-based smoke test (--smoke-test) ────────────────
if [[ "$SMOKE_TEST" -eq 1 ]]; then
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo " STEP 8: Smoke test (launches one runner to verify end-to-end)"
    echo "═══════════════════════════════════════════════════════════════"

    # Refuse to smoke if there's any in-flight stable work. The cleanup
    # trap scales ASG to 0 unconditionally — running smoke on top of a
    # live build would kill it. Run smoke only during quiet windows.
    EXISTING_DESIRED=$(aws autoscaling describe-auto-scaling-groups \
        --auto-scaling-group-names "$STABLE_ASG" \
        --region "$AWS_REGION" \
        --query 'AutoScalingGroups[0].DesiredCapacity' \
        --output text)
    EXISTING_INSTS=$(aws autoscaling describe-auto-scaling-groups \
        --auto-scaling-group-names "$STABLE_ASG" \
        --region "$AWS_REGION" \
        --query 'length(AutoScalingGroups[0].Instances)' \
        --output text)
    if [[ "$EXISTING_DESIRED" -gt 0 || "$EXISTING_INSTS" -gt 0 ]]; then
        err "Refusing to smoke: $STABLE_ASG has desired=$EXISTING_DESIRED, instances=$EXISTING_INSTS. Wait for stable runners to finish, then re-run."
    fi
    log "Stable ASG is quiet (desired=0, no instances) — safe to smoke"

    # We need to read user-data trace from EC2 console output, but the
    # production user-data redirects everything to a file (`exec >
    # /var/log/runner-setup.log 2>&1`). Trick: create a temporary LT
    # version that swaps that redirect for `tee /dev/console` so the
    # `set -x` trace shows up in the EC2 console. We run the smoke
    # against that version, then restore the previous default.
    #
    # Cleanup-on-exit trap: ALWAYS restore the previous default version
    # and scale the ASG back to 0, even on Ctrl-C / shell errors. The
    # smoke version is left in place (cheap, useful for debugging).
    PREV_DEFAULT=$(aws ec2 describe-launch-templates \
        --launch-template-names "$STABLE_LT" \
        --region "$AWS_REGION" \
        --query 'LaunchTemplates[0].DefaultVersionNumber' \
        --output text)
    SMOKE_LT_DATA=$(echo "$STABLE_LT_DATA" | jq --arg ud \
        "$(echo "$STABLE_USER_DATA" \
            | sed 's|^exec > /var/log/runner-setup.log 2>&1$|exec > >(tee -a /var/log/runner-setup.log /dev/console) 2>\&1|' \
            | base64 -w 0)" \
        '.UserData = $ud')
    SMOKE_FILE="$(mktemp -t smoke-lt-XXXX.json)"
    # Convert POSIX path → Windows for AWS CLI (Git-Bash compatibility)
    if command -v cygpath >/dev/null 2>&1; then
        SMOKE_FILE_WIN=$(cygpath -w "$SMOKE_FILE")
    else
        SMOKE_FILE_WIN="$SMOKE_FILE"
    fi
    echo "$SMOKE_LT_DATA" > "$SMOKE_FILE"
    SMOKE_VERSION=$(aws ec2 create-launch-template-version \
        --launch-template-name "$STABLE_LT" \
        --source-version '$Latest' \
        --launch-template-data "file://$SMOKE_FILE_WIN" \
        --version-description "smoke-test (console redirect for diagnostics)" \
        --region "$AWS_REGION" \
        --query 'LaunchTemplateVersion.VersionNumber' \
        --output text)
    rm -f "$SMOKE_FILE"
    log "Smoke LT version: $SMOKE_VERSION (will be restored to v$PREV_DEFAULT after smoke)"

    # Cleanup trap fires on any exit path (success, error, signal).
    # Order matters: scale-down first, then restore default version.
    cleanup_smoke() {
        local exit_code=$?
        echo ""
        warn "Smoke cleanup (exit_code=$exit_code)..."
        aws autoscaling set-desired-capacity \
            --auto-scaling-group-name "$STABLE_ASG" \
            --desired-capacity 0 \
            --region "$AWS_REGION" 2>/dev/null || true
        aws ec2 modify-launch-template \
            --launch-template-name "$STABLE_LT" \
            --default-version "$PREV_DEFAULT" \
            --region "$AWS_REGION" >/dev/null 2>&1 || true
        log "Smoke cleanup done (ASG scaled to 0, default version restored to v$PREV_DEFAULT)"
    }
    trap cleanup_smoke EXIT

    # Promote the smoke version to default and scale up
    aws ec2 modify-launch-template \
        --launch-template-name "$STABLE_LT" \
        --default-version "$SMOKE_VERSION" \
        --region "$AWS_REGION" >/dev/null
    aws autoscaling set-desired-capacity \
        --auto-scaling-group-name "$STABLE_ASG" \
        --desired-capacity 1 \
        --region "$AWS_REGION"
    log "Smoke ASG scaled to 1, waiting for InService..."

    # Wait up to 3 min for InService instance
    SMOKE_INST=""
    for _ in $(seq 1 36); do
        SMOKE_INST=$(aws autoscaling describe-auto-scaling-groups \
            --auto-scaling-group-names "$STABLE_ASG" \
            --region "$AWS_REGION" \
            --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`].InstanceId' \
            --output text 2>/dev/null | tr -d '\r')
        [[ -n "$SMOKE_INST" ]] && break
        sleep 5
    done
    [[ -z "$SMOKE_INST" ]] && err "Smoke: no InService instance after 3 min"
    log "Smoke instance: $SMOKE_INST"

    # Wait up to 3 min for user-data to finish + console output to populate.
    # Success markers (in priority order): "Settings Saved" (config.sh),
    # "/usr/local/bin/idle-watchdog.sh" (last command in user-data).
    # Failure markers: "config.sh: No such file or directory" (broken AMI),
    # "Authentication failed" (PAT issue).
    SMOKE_RESULT=""
    for _ in $(seq 1 36); do
        sleep 5
        OUT=$(aws ec2 get-console-output \
            --instance-id "$SMOKE_INST" \
            --latest \
            --region "$AWS_REGION" \
            --query 'Output' --output text 2>/dev/null || true)
        if echo "$OUT" | grep -qE "config\.sh: No such file|svc\.sh: No such file"; then
            SMOKE_RESULT="FAIL: runner binary missing on AMI ($EXPECTED_AMI)"
            break
        fi
        if echo "$OUT" | grep -qE "Http response code: Unauthorized|Authentication failed"; then
            SMOKE_RESULT="FAIL: GitHub PAT in /gh-runner/github-pat is invalid or expired"
            break
        fi
        if echo "$OUT" | grep -q "Settings Saved\."; then
            SMOKE_RESULT="PASS: runner registered with GitHub (config.sh succeeded)"
            break
        fi
    done

    if [[ -z "$SMOKE_RESULT" ]]; then
        SMOKE_RESULT="INCONCLUSIVE: 3 min elapsed, no success or failure marker on console — check $SMOKE_INST manually"
    fi

    if [[ "$SMOKE_RESULT" == PASS:* ]]; then
        log "Smoke: $SMOKE_RESULT"
    else
        err "Smoke: $SMOKE_RESULT"
    fi
    # cleanup_smoke trap runs on exit
fi

# ─── DONE ────────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo " STABLE TIER PROVISIONED"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "  ASG:          $STABLE_ASG (on-demand, c7g.2xlarge)"
echo "  Cost:         ~\$0.29/hr per active runner (~5x spot)"
echo "  Use in workflows for jobs whose cancellation hurts:"
echo ""
echo "    runs-on: [self-hosted, linux, arm64, stable]"
echo ""
