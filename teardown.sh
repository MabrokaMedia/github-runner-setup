#!/bin/bash
set -euo pipefail

# =============================================================================
# Teardown: Remove all GitHub Actions runner infrastructure
# =============================================================================

# ─── CONFIGURATION (must match setup.sh) ─────────────────────────────────────
ORG_NAME=""                          # <-- Same org name as setup.sh
AWS_REGION="us-east-2"
# ─────────────────────────────────────────────────────────────────────────────

PREFIX="gh-runner"
EC2_ROLE="${PREFIX}-ec2-role"
LAMBDA_ROLE="${PREFIX}-lambda-role"
SG_NAME="${PREFIX}-sg"
LT_NAME="${PREFIX}-lt"
ASG_NAME="${PREFIX}-asg"
LAMBDA_NAME="${PREFIX}-scaler"
API_NAME="${PREFIX}-webhook"
SSM_PAT="/${PREFIX}/github-pat"
SSM_SECRET="/${PREFIX}/webhook-secret"
SSM_ORG="/${PREFIX}/org-name"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }

[[ -z "$ORG_NAME" ]] && { echo -e "${RED}[✗]${NC} Set ORG_NAME at the top of this script"; exit 1; }

echo ""
echo "This will DELETE all GitHub runner infrastructure."
echo "Resources: ASG, Launch Template, Lambda, API Gateway, IAM roles, SSM params, webhook"
echo ""
read -rp "Type 'yes' to confirm: " CONFIRM
[[ "$CONFIRM" != "yes" ]] && { echo "Aborted."; exit 0; }

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# 1. Delete GitHub webhook
echo ""
WEBHOOK_URL_PATTERN="execute-api.${AWS_REGION}.amazonaws.com/webhook"
HOOK_ID=$(gh api "orgs/$ORG_NAME/hooks" --jq ".[] | select(.config.url | contains(\"$WEBHOOK_URL_PATTERN\")) | .id" 2>/dev/null || echo "")
if [[ -n "$HOOK_ID" ]]; then
    gh api "orgs/$ORG_NAME/hooks/$HOOK_ID" -X DELETE
    log "Deleted GitHub webhook: $HOOK_ID"
else
    warn "No matching GitHub webhook found"
fi

# 2. Delete API Gateway
API_ID=$(aws apigatewayv2 get-apis --region "$AWS_REGION" \
    | jq -r ".Items[] | select(.Name==\"$API_NAME\") | .ApiId" 2>/dev/null | head -1 || echo "")
if [[ -n "$API_ID" ]]; then
    aws apigatewayv2 delete-api --api-id "$API_ID" --region "$AWS_REGION"
    log "Deleted API Gateway: $API_ID"
else
    warn "API Gateway not found"
fi

# 3. Delete Lambda
if aws lambda get-function --function-name "$LAMBDA_NAME" --region "$AWS_REGION" &>/dev/null; then
    aws lambda delete-function --function-name "$LAMBDA_NAME" --region "$AWS_REGION"
    log "Deleted Lambda: $LAMBDA_NAME"
else
    warn "Lambda not found"
fi

# 4. Delete ASG (force, terminates instances)
ASG_EXISTS=$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$ASG_NAME" \
    --query "AutoScalingGroups | length(@)" --output text --region "$AWS_REGION")
if [[ "$ASG_EXISTS" -gt 0 ]]; then
    aws autoscaling update-auto-scaling-group \
        --auto-scaling-group-name "$ASG_NAME" \
        --min-size 0 --max-size 0 --desired-capacity 0 \
        --region "$AWS_REGION"
    sleep 5
    aws autoscaling delete-auto-scaling-group \
        --auto-scaling-group-name "$ASG_NAME" \
        --force-delete \
        --region "$AWS_REGION"
    log "Deleted ASG: $ASG_NAME"
else
    warn "ASG not found"
fi

# 5. Delete Launch Template
if aws ec2 describe-launch-templates --launch-template-names "$LT_NAME" --region "$AWS_REGION" &>/dev/null; then
    aws ec2 delete-launch-template --launch-template-name "$LT_NAME" --region "$AWS_REGION"
    log "Deleted Launch Template: $LT_NAME"
else
    warn "Launch Template not found"
fi

# 6. Delete Security Group
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" \
    --query "Vpcs[0].VpcId" --output text --region "$AWS_REGION")
SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
    --query "SecurityGroups[0].GroupId" --output text --region "$AWS_REGION" 2>/dev/null || echo "None")
if [[ "$SG_ID" != "None" && -n "$SG_ID" ]]; then
    aws ec2 delete-security-group --group-id "$SG_ID" --region "$AWS_REGION"
    log "Deleted Security Group: $SG_ID"
else
    warn "Security Group not found"
fi

# 7. Delete IAM roles
for ROLE in "$EC2_ROLE" "$LAMBDA_ROLE"; do
    if aws iam get-role --role-name "$ROLE" &>/dev/null; then
        # Delete inline policies
        POLICIES=$(aws iam list-role-policies --role-name "$ROLE" --query "PolicyNames" --output text)
        for P in $POLICIES; do
            aws iam delete-role-policy --role-name "$ROLE" --policy-name "$P"
        done
        # Remove from instance profile if EC2 role
        if [[ "$ROLE" == "$EC2_ROLE" ]]; then
            aws iam remove-role-from-instance-profile \
                --instance-profile-name "$ROLE" --role-name "$ROLE" 2>/dev/null || true
            aws iam delete-instance-profile --instance-profile-name "$ROLE" 2>/dev/null || true
        fi
        aws iam delete-role --role-name "$ROLE"
        log "Deleted IAM role: $ROLE"
    else
        warn "IAM role $ROLE not found"
    fi
done

# 8. Delete SSM parameters
for PARAM in "$SSM_PAT" "$SSM_SECRET" "$SSM_ORG"; do
    if aws ssm get-parameter --name "$PARAM" --region "$AWS_REGION" &>/dev/null; then
        aws ssm delete-parameter --name "$PARAM" --region "$AWS_REGION"
        log "Deleted SSM parameter: $PARAM"
    fi
done

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo " TEARDOWN COMPLETE - All resources removed"
echo "═══════════════════════════════════════════════════════════════"
