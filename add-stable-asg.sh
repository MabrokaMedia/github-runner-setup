#!/bin/bash
set -euo pipefail

# =============================================================================
# Add a third runner tier: gh-runner-stable-asg (100% on-demand)
# =============================================================================
# Why:
#   The fast and small ASGs are 100% spot. Long-running jobs (cargo lambda
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
#   AWS_REGION=us-east-1 bash add-stable-asg.sh
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

FAST_LT_DATA=$(aws ec2 describe-launch-template-versions \
    --launch-template-name "$FAST_LT" \
    --versions '$Latest' \
    --region "$AWS_REGION" \
    --query 'LaunchTemplateVersions[0].LaunchTemplateData' \
    --output json) || err "Fast LT $FAST_LT not found — run setup.sh first"

# Strip spot config, keep everything else (AMI, instance profile, SG, user data, EBS, tags)
STABLE_LT_DATA=$(echo "$FAST_LT_DATA" | jq 'del(.InstanceMarketOptions)')
log "Mirrored fast LT, removed InstanceMarketOptions (becomes on-demand)"

# ─── STEP 2: Create or update stable launch template ────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo " STEP 2: Stable launch template"
echo "═══════════════════════════════════════════════════════════════"

STABLE_LT_EXISTS=$(aws ec2 describe-launch-templates \
    --launch-template-names "$STABLE_LT" \
    --region "$AWS_REGION" 2>/dev/null | jq -r '.LaunchTemplates | length')

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

# Suspend AZ rebalancing — same rationale as the fast/small ASGs (ephemeral
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

for asg in "$FAST_ASG" "${PREFIX}-small-asg"; do
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

NEW_ENV=$(echo "$CURRENT_ENV" | jq --arg v "$STABLE_ASG" '. + {STABLE_ASG_NAME: $v}')

aws lambda update-function-configuration \
    --function-name "$LAMBDA_NAME" \
    --environment "Variables=$(echo "$NEW_ENV" | jq -c .)" \
    --region "$AWS_REGION" >/dev/null
log "Lambda $LAMBDA_NAME env updated: STABLE_ASG_NAME=$STABLE_ASG"

warn "NOTE: also deploy the updated lambda/scaler.py — env alone won't route the 'stable' label."
warn "      cd lambda && zip -j /tmp/scaler.zip scaler.py && \\"
warn "      aws lambda update-function-code --function-name $LAMBDA_NAME \\"
warn "        --zip-file fileb:///tmp/scaler.zip --region $AWS_REGION"

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
