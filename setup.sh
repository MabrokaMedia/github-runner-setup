#!/bin/bash
set -euo pipefail

# =============================================================================
# GitHub Actions Self-Hosted Runner on AWS EC2 Spot (Scale-to-Zero)
# =============================================================================
# Architecture:
#   GitHub webhook → API Gateway → Lambda → Scale ASG → EC2 Spot (c7g.2xlarge)
#   Runner runs 1 job (ephemeral) → self-terminates → ASG scales back to 0
#
# Cost: ~$0.035/hr ONLY when jobs are running. $0 when idle.
#
# Prerequisites:
#   - AWS CLI v2 configured with admin-level credentials
#   - GitHub CLI (gh) authenticated with your org
#   - jq, zip installed
#   - Run from WSL or Git Bash on Windows
# =============================================================================

# ─── CONFIGURATION (edit these) ──────────────────────────────────────────────
ORG_NAME=""                          # <-- Your GitHub org name (REQUIRED)
AWS_REGION="us-east-2"               # <-- Your AWS region
INSTANCE_TYPE="c7g.2xlarge"          # 8 vCPU, 16GB RAM, Arm64
MAX_RUNNERS=10                       # Max concurrent runners
RUNNER_LABELS="self-hosted,linux,arm64,fast"
CACHE_BUCKET="mabroka-ci-cache"      # S3 bucket for CI cache (same region for $0 egress)
# ─────────────────────────────────────────────────────────────────────────────

# Derived names
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

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# ─── VALIDATION ──────────────────────────────────────────────────────────────
[[ -z "$ORG_NAME" ]] && err "Set ORG_NAME at the top of this script"
command -v aws  >/dev/null || err "AWS CLI not found"
command -v gh   >/dev/null || err "GitHub CLI not found"
command -v jq   >/dev/null || err "jq not found"
command -v zip  >/dev/null || err "zip not found"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
log "AWS Account: $ACCOUNT_ID | Region: $AWS_REGION | Org: $ORG_NAME"

# ─── STEP 1: Generate & store secrets in SSM ────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo " STEP 1: Store GitHub PAT & webhook secret in SSM"
echo "═══════════════════════════════════════════════════════════════"

# Check if PAT already exists
if aws ssm get-parameter --name "$SSM_PAT" --region "$AWS_REGION" &>/dev/null; then
    warn "GitHub PAT already in SSM ($SSM_PAT). Skipping."
else
    echo ""
    echo "Create a GitHub PAT (classic) with these scopes:"
    echo "  - admin:org  (to register org-level runners)"
    echo "  - repo       (if you want repo-level access)"
    echo ""
    echo "Create at: https://github.com/settings/tokens/new"
    echo ""
    read -rsp "Paste your GitHub PAT: " GH_PAT
    echo ""

    aws ssm put-parameter \
        --name "$SSM_PAT" \
        --type SecureString \
        --value "$GH_PAT" \
        --region "$AWS_REGION" \
        --overwrite
    log "GitHub PAT stored in SSM: $SSM_PAT"
fi

# Generate webhook secret
if aws ssm get-parameter --name "$SSM_SECRET" --region "$AWS_REGION" &>/dev/null; then
    warn "Webhook secret already in SSM ($SSM_SECRET). Skipping."
    WEBHOOK_SECRET=$(aws ssm get-parameter --name "$SSM_SECRET" --with-decryption --query "Parameter.Value" --output text --region "$AWS_REGION")
else
    WEBHOOK_SECRET=$(openssl rand -hex 20)
    aws ssm put-parameter \
        --name "$SSM_SECRET" \
        --type SecureString \
        --value "$WEBHOOK_SECRET" \
        --region "$AWS_REGION" \
        --overwrite
    log "Webhook secret generated and stored in SSM: $SSM_SECRET"
fi

# ─── STEP 1.5: S3 bucket for CI cache (same region → $0 egress) ─────────────
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo " STEP 1.5: S3 bucket for CI cache"
echo "═══════════════════════════════════════════════════════════════"

if aws s3api head-bucket --bucket "$CACHE_BUCKET" --region "$AWS_REGION" 2>/dev/null; then
    warn "S3 bucket $CACHE_BUCKET already exists. Skipping."
else
    if [[ "$AWS_REGION" == "us-east-1" ]]; then
        aws s3api create-bucket --bucket "$CACHE_BUCKET" --region "$AWS_REGION" >/dev/null
    else
        aws s3api create-bucket --bucket "$CACHE_BUCKET" --region "$AWS_REGION" \
            --create-bucket-configuration "LocationConstraint=$AWS_REGION" >/dev/null
    fi

    aws s3api put-bucket-tagging --bucket "$CACHE_BUCKET" \
        --tagging "TagSet=[{Key=Purpose,Value=ci-cache},{Key=ManagedBy,Value=${PREFIX}}]"

    aws s3api put-public-access-block --bucket "$CACHE_BUCKET" \
        --public-access-block-configuration \
        'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'

    aws s3api put-bucket-lifecycle-configuration --bucket "$CACHE_BUCKET" \
        --lifecycle-configuration \
        '{"Rules":[{"ID":"expire-after-7-days","Status":"Enabled","Filter":{"Prefix":""},"Expiration":{"Days":7}}]}'

    log "Created S3 cache bucket: $CACHE_BUCKET (7-day expiry)"
fi

# ─── STEP 2: IAM Role for EC2 Runner ────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo " STEP 2: IAM Role for EC2 Runner"
echo "═══════════════════════════════════════════════════════════════"

if aws iam get-role --role-name "$EC2_ROLE" &>/dev/null; then
    warn "IAM role $EC2_ROLE already exists. Skipping."
else
    # Trust policy for EC2
    aws iam create-role \
        --role-name "$EC2_ROLE" \
        --assume-role-policy-document '{
            "Version": "2012-10-17",
            "Statement": [{
                "Effect": "Allow",
                "Principal": {"Service": "ec2.amazonaws.com"},
                "Action": "sts:AssumeRole"
            }]
        }'

    # Inline policy: SSM read + self-terminate + ASG decrement + S3 cache access
    aws iam put-role-policy \
        --role-name "$EC2_ROLE" \
        --policy-name "${PREFIX}-ec2-policy" \
        --policy-document "{
            \"Version\": \"2012-10-17\",
            \"Statement\": [
                {
                    \"Effect\": \"Allow\",
                    \"Action\": [\"ssm:GetParameter\"],
                    \"Resource\": \"arn:aws:ssm:${AWS_REGION}:${ACCOUNT_ID}:parameter/${PREFIX}/*\"
                },
                {
                    \"Effect\": \"Allow\",
                    \"Action\": [
                        \"ec2:TerminateInstances\",
                        \"ec2:DescribeInstances\",
                        \"ec2:DescribeTags\"
                    ],
                    \"Resource\": \"*\"
                },
                {
                    \"Effect\": \"Allow\",
                    \"Action\": [
                        \"autoscaling:SetDesiredCapacity\",
                        \"autoscaling:DescribeAutoScalingGroups\",
                        \"autoscaling:TerminateInstanceInAutoScalingGroup\"
                    ],
                    \"Resource\": \"*\"
                },
                {
                    \"Effect\": \"Allow\",
                    \"Action\": [
                        \"s3:GetObject\",
                        \"s3:PutObject\",
                        \"s3:DeleteObject\",
                        \"s3:AbortMultipartUpload\"
                    ],
                    \"Resource\": \"arn:aws:s3:::${CACHE_BUCKET}/*\"
                },
                {
                    \"Effect\": \"Allow\",
                    \"Action\": [\"s3:ListBucket\"],
                    \"Resource\": \"arn:aws:s3:::${CACHE_BUCKET}\"
                }
            ]
        }"

    log "Created IAM role: $EC2_ROLE"
fi

# Create instance profile
if aws iam get-instance-profile --instance-profile-name "$EC2_ROLE" &>/dev/null; then
    warn "Instance profile $EC2_ROLE already exists."
else
    aws iam create-instance-profile --instance-profile-name "$EC2_ROLE"
    aws iam add-role-to-instance-profile \
        --instance-profile-name "$EC2_ROLE" \
        --role-name "$EC2_ROLE"
    log "Created instance profile: $EC2_ROLE"
    sleep 10  # Wait for propagation
fi

# ─── STEP 3: IAM Role for Lambda ────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo " STEP 3: IAM Role for Lambda"
echo "═══════════════════════════════════════════════════════════════"

if aws iam get-role --role-name "$LAMBDA_ROLE" &>/dev/null; then
    warn "IAM role $LAMBDA_ROLE already exists. Skipping."
else
    aws iam create-role \
        --role-name "$LAMBDA_ROLE" \
        --assume-role-policy-document '{
            "Version": "2012-10-17",
            "Statement": [{
                "Effect": "Allow",
                "Principal": {"Service": "lambda.amazonaws.com"},
                "Action": "sts:AssumeRole"
            }]
        }'

    aws iam put-role-policy \
        --role-name "$LAMBDA_ROLE" \
        --policy-name "${PREFIX}-lambda-policy" \
        --policy-document "{
            \"Version\": \"2012-10-17\",
            \"Statement\": [
                {
                    \"Effect\": \"Allow\",
                    \"Action\": [
                        \"logs:CreateLogGroup\",
                        \"logs:CreateLogStream\",
                        \"logs:PutLogEvents\"
                    ],
                    \"Resource\": \"arn:aws:logs:${AWS_REGION}:${ACCOUNT_ID}:*\"
                },
                {
                    \"Effect\": \"Allow\",
                    \"Action\": [\"ssm:GetParameter\"],
                    \"Resource\": \"arn:aws:ssm:${AWS_REGION}:${ACCOUNT_ID}:parameter/${PREFIX}/*\"
                },
                {
                    \"Effect\": \"Allow\",
                    \"Action\": [
                        \"autoscaling:SetDesiredCapacity\",
                        \"autoscaling:DescribeAutoScalingGroups\"
                    ],
                    \"Resource\": \"*\"
                }
            ]
        }"

    log "Created IAM role: $LAMBDA_ROLE"
    sleep 10  # Wait for propagation
fi

# ─── STEP 4: Security Group ─────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo " STEP 4: Security Group (outbound-only)"
echo "═══════════════════════════════════════════════════════════════"

VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" \
    --query "Vpcs[0].VpcId" --output text --region "$AWS_REGION")

SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
    --query "SecurityGroups[0].GroupId" --output text --region "$AWS_REGION" 2>/dev/null || echo "None")

if [[ "$SG_ID" != "None" && -n "$SG_ID" ]]; then
    warn "Security group $SG_NAME already exists: $SG_ID"
else
    SG_ID=$(aws ec2 create-security-group \
        --group-name "$SG_NAME" \
        --description "GitHub Actions runner - outbound only" \
        --vpc-id "$VPC_ID" \
        --query "GroupId" --output text \
        --region "$AWS_REGION")

    # Remove default inbound rule (allow nothing inbound)
    aws ec2 revoke-security-group-ingress \
        --group-id "$SG_ID" \
        --protocol all \
        --source-group "$SG_ID" \
        --region "$AWS_REGION" 2>/dev/null || true

    log "Created security group: $SG_ID (outbound-only)"
fi

# ─── STEP 5: Launch Template ────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo " STEP 5: Launch Template (EC2 Spot + runner user data)"
echo "═══════════════════════════════════════════════════════════════"

# Get latest Amazon Linux 2023 ARM64 AMI
AMI_ID=$(aws ec2 describe-images \
    --owners amazon \
    --filters "Name=name,Values=al2023-ami-2023*-arm64" \
              "Name=state,Values=available" \
    --query "sort_by(Images, &CreationDate)[-1].ImageId" \
    --output text --region "$AWS_REGION")

log "Using AMI: $AMI_ID (Amazon Linux 2023 ARM64)"

# User data script (runs on each EC2 boot)
USER_DATA=$(cat <<'USERDATA'
#!/bin/bash
set -euo pipefail
exec > /var/log/runner-setup.log 2>&1

REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)

echo "=== Installing dependencies ==="
dnf install -y git docker jq libicu tar gzip zstd

# Start Docker
systemctl enable docker
systemctl start docker

# Create runner user
useradd -m runner
usermod -aG docker runner

echo "=== Fetching GitHub PAT from SSM ==="
GH_PAT=$(aws ssm get-parameter --name "/gh-runner/github-pat" --with-decryption \
    --query "Parameter.Value" --output text --region "$REGION")

ORG_NAME=$(aws ssm get-parameter --name "/gh-runner/org-name" \
    --query "Parameter.Value" --output text --region "$REGION" 2>/dev/null || echo "")

if [[ -z "$ORG_NAME" ]]; then
    echo "ERROR: /gh-runner/org-name not found in SSM"
    exit 1
fi

echo "=== Getting registration token ==="
REG_TOKEN=$(curl -s -X POST \
    -H "Authorization: token ${GH_PAT}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/orgs/${ORG_NAME}/actions/runners/registration-token" \
    | jq -r .token)

echo "=== Installing GitHub Actions Runner ==="
cd /home/runner
RUNNER_VERSION=$(curl -s https://api.github.com/repos/actions/runner/releases/latest | jq -r .tag_name | tr -d 'v')
RUNNER_ARCH="arm64"
RUNNER_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"

curl -sL "$RUNNER_URL" -o runner.tar.gz
tar xzf runner.tar.gz
rm runner.tar.gz
chown -R runner:runner /home/runner

echo "=== Configuring runner ==="
su - runner -c "/home/runner/config.sh \
    --url https://github.com/${ORG_NAME} \
    --token ${REG_TOKEN} \
    --name runner-${INSTANCE_ID} \
    --labels self-hosted,linux,arm64,fast \
    --ephemeral \
    --unattended"

echo "=== Starting runner (ephemeral - will exit after 1 job) ==="
su - runner -c "/home/runner/run.sh" || true

echo "=== Job complete. Self-terminating ==="
ASG_NAME=$(aws ec2 describe-tags \
    --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=aws:autoscaling:groupName" \
    --query "Tags[0].Value" --output text --region "$REGION")

if [[ -n "$ASG_NAME" && "$ASG_NAME" != "None" ]]; then
    aws autoscaling terminate-instance-in-auto-scaling-group \
        --instance-id "$INSTANCE_ID" \
        --should-decrement-desired-capacity \
        --region "$REGION"
else
    aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$REGION"
fi
USERDATA
)

USER_DATA_B64=$(echo "$USER_DATA" | base64 -w 0)

# Get a single subnet for ASG (single AZ — no rebalancing needed for ephemeral runners)
PREFERRED_AZ="${AWS_REGION}a"
SUBNETS=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=availability-zone,Values=$PREFERRED_AZ" "Name=default-for-az,Values=true" \
    --query "Subnets[0].SubnetId" --output text --region "$AWS_REGION")
log "Using single AZ: $PREFERRED_AZ (subnet: $SUBNETS)"

# Check if launch template exists
LT_EXISTS=$(aws ec2 describe-launch-templates \
    --launch-template-names "$LT_NAME" \
    --region "$AWS_REGION" 2>/dev/null | jq -r '.LaunchTemplates | length')

if [[ "$LT_EXISTS" -gt 0 ]]; then
    # Create new version
    aws ec2 create-launch-template-version \
        --launch-template-name "$LT_NAME" \
        --source-version '$Latest' \
        --launch-template-data "{
            \"ImageId\": \"$AMI_ID\",
            \"InstanceType\": \"$INSTANCE_TYPE\",
            \"IamInstanceProfile\": {\"Name\": \"$EC2_ROLE\"},
            \"SecurityGroupIds\": [\"$SG_ID\"],
            \"UserData\": \"$USER_DATA_B64\",
            \"InstanceMarketOptions\": {
                \"MarketType\": \"spot\",
                \"SpotOptions\": {
                    \"SpotInstanceType\": \"one-time\",
                    \"InstanceInterruptionBehavior\": \"terminate\"
                }
            },
            \"TagSpecifications\": [{
                \"ResourceType\": \"instance\",
                \"Tags\": [
                    {\"Key\": \"Name\", \"Value\": \"github-runner\"},
                    {\"Key\": \"Purpose\", \"Value\": \"github-runner\"}
                ]
            }],
            \"BlockDeviceMappings\": [{
                \"DeviceName\": \"/dev/xvda\",
                \"Ebs\": {
                    \"VolumeSize\": 80,
                    \"VolumeType\": \"gp3\",
                    \"DeleteOnTermination\": true
                }
            }]
        }" \
        --region "$AWS_REGION"
    warn "Updated launch template: $LT_NAME"
else
    aws ec2 create-launch-template \
        --launch-template-name "$LT_NAME" \
        --launch-template-data "{
            \"ImageId\": \"$AMI_ID\",
            \"InstanceType\": \"$INSTANCE_TYPE\",
            \"IamInstanceProfile\": {\"Name\": \"$EC2_ROLE\"},
            \"SecurityGroupIds\": [\"$SG_ID\"],
            \"UserData\": \"$USER_DATA_B64\",
            \"InstanceMarketOptions\": {
                \"MarketType\": \"spot\",
                \"SpotOptions\": {
                    \"SpotInstanceType\": \"one-time\",
                    \"InstanceInterruptionBehavior\": \"terminate\"
                }
            },
            \"TagSpecifications\": [{
                \"ResourceType\": \"instance\",
                \"Tags\": [
                    {\"Key\": \"Name\", \"Value\": \"github-runner\"},
                    {\"Key\": \"Purpose\", \"Value\": \"github-runner\"}
                ]
            }],
            \"BlockDeviceMappings\": [{
                \"DeviceName\": \"/dev/xvda\",
                \"Ebs\": {
                    \"VolumeSize\": 80,
                    \"VolumeType\": \"gp3\",
                    \"DeleteOnTermination\": true
                }
            }]
        }" \
        --region "$AWS_REGION"
    log "Created launch template: $LT_NAME"
fi

# ─── STEP 6: Auto Scaling Group (min=0, scale-to-zero) ──────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo " STEP 6: Auto Scaling Group (scale-to-zero)"
echo "═══════════════════════════════════════════════════════════════"

ASG_EXISTS=$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$ASG_NAME" \
    --query "AutoScalingGroups | length(@)" --output text \
    --region "$AWS_REGION")

if [[ "$ASG_EXISTS" -gt 0 ]]; then
    warn "ASG $ASG_NAME already exists. Updating."
    aws autoscaling update-auto-scaling-group \
        --auto-scaling-group-name "$ASG_NAME" \
        --launch-template "LaunchTemplateName=$LT_NAME,Version=\$Latest" \
        --min-size 0 --max-size "$MAX_RUNNERS" --desired-capacity 0 \
        --region "$AWS_REGION"
else
    aws autoscaling create-auto-scaling-group \
        --auto-scaling-group-name "$ASG_NAME" \
        --launch-template "LaunchTemplateName=$LT_NAME,Version=\$Latest" \
        --min-size 0 --max-size "$MAX_RUNNERS" --desired-capacity 0 \
        --vpc-zone-identifier "$SUBNETS" \
        --tags "Key=Name,Value=github-runner,PropagateAtLaunch=true" \
        --region "$AWS_REGION"
    log "Created ASG: $ASG_NAME (min=0, max=$MAX_RUNNERS, desired=0)"
fi

# Suspend AZ rebalancing (ephemeral runners don't need cross-AZ HA)
aws autoscaling suspend-processes \
    --auto-scaling-group-name "$ASG_NAME" \
    --scaling-processes AZRebalance \
    --region "$AWS_REGION"
log "Suspended AZRebalance process (not needed for ephemeral runners)"

# ─── STEP 7: Store org name in SSM (for EC2 user data) ──────────────────────
aws ssm put-parameter \
    --name "/${PREFIX}/org-name" \
    --type String \
    --value "$ORG_NAME" \
    --region "$AWS_REGION" \
    --overwrite >/dev/null
log "Stored org name in SSM: /${PREFIX}/org-name"

# ─── STEP 8: Lambda Function ────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo " STEP 8: Lambda Function (webhook handler)"
echo "═══════════════════════════════════════════════════════════════"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/lambda"
zip -j /tmp/scaler.zip scaler.py
cd "$SCRIPT_DIR"

LAMBDA_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${LAMBDA_ROLE}"

LAMBDA_EXISTS=$(aws lambda get-function --function-name "$LAMBDA_NAME" \
    --region "$AWS_REGION" 2>/dev/null && echo "yes" || echo "no")

if [[ "$LAMBDA_EXISTS" == "yes" ]]; then
    aws lambda update-function-code \
        --function-name "$LAMBDA_NAME" \
        --zip-file fileb:///tmp/scaler.zip \
        --region "$AWS_REGION" >/dev/null

    aws lambda update-function-configuration \
        --function-name "$LAMBDA_NAME" \
        --environment "Variables={ASG_NAME=$ASG_NAME,MAX_RUNNERS=$MAX_RUNNERS,WEBHOOK_SECRET_PARAM=$SSM_SECRET,RUNNER_LABELS=$RUNNER_LABELS}" \
        --region "$AWS_REGION" >/dev/null

    warn "Updated Lambda: $LAMBDA_NAME"
else
    aws lambda create-function \
        --function-name "$LAMBDA_NAME" \
        --runtime python3.12 \
        --handler scaler.handler \
        --role "$LAMBDA_ROLE_ARN" \
        --zip-file fileb:///tmp/scaler.zip \
        --timeout 30 \
        --memory-size 128 \
        --environment "Variables={ASG_NAME=$ASG_NAME,MAX_RUNNERS=$MAX_RUNNERS,WEBHOOK_SECRET_PARAM=$SSM_SECRET,RUNNER_LABELS=$RUNNER_LABELS}" \
        --region "$AWS_REGION" >/dev/null
    log "Created Lambda: $LAMBDA_NAME"
fi

rm -f /tmp/scaler.zip
LAMBDA_ARN=$(aws lambda get-function --function-name "$LAMBDA_NAME" \
    --query "Configuration.FunctionArn" --output text --region "$AWS_REGION")

# ─── STEP 9: API Gateway (HTTP API v2) ──────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo " STEP 9: API Gateway (webhook endpoint)"
echo "═══════════════════════════════════════════════════════════════"

API_ID=$(aws apigatewayv2 get-apis --region "$AWS_REGION" \
    | jq -r ".Items[] | select(.Name==\"$API_NAME\") | .ApiId" | head -1)

if [[ -n "$API_ID" ]]; then
    warn "API Gateway $API_NAME already exists: $API_ID"
else
    API_ID=$(aws apigatewayv2 create-api \
        --name "$API_NAME" \
        --protocol-type HTTP \
        --query "ApiId" --output text \
        --region "$AWS_REGION")

    # Integration (Lambda)
    INTEGRATION_ID=$(aws apigatewayv2 create-integration \
        --api-id "$API_ID" \
        --integration-type AWS_PROXY \
        --integration-uri "$LAMBDA_ARN" \
        --payload-format-version "2.0" \
        --query "IntegrationId" --output text \
        --region "$AWS_REGION")

    # Route: POST /webhook
    aws apigatewayv2 create-route \
        --api-id "$API_ID" \
        --route-key "POST /webhook" \
        --target "integrations/$INTEGRATION_ID" \
        --region "$AWS_REGION" >/dev/null

    # Deploy to $default stage
    aws apigatewayv2 create-stage \
        --api-id "$API_ID" \
        --stage-name '$default' \
        --auto-deploy \
        --region "$AWS_REGION" >/dev/null

    # Grant API Gateway permission to invoke Lambda
    aws lambda add-permission \
        --function-name "$LAMBDA_NAME" \
        --statement-id "apigateway-invoke" \
        --action "lambda:InvokeFunction" \
        --principal "apigateway.amazonaws.com" \
        --source-arn "arn:aws:execute-api:${AWS_REGION}:${ACCOUNT_ID}:${API_ID}/*" \
        --region "$AWS_REGION" >/dev/null

    log "Created API Gateway: $API_ID"
fi

WEBHOOK_URL="https://${API_ID}.execute-api.${AWS_REGION}.amazonaws.com/webhook"
log "Webhook URL: $WEBHOOK_URL"

# ─── STEP 10: GitHub Organization Webhook ────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo " STEP 10: GitHub Organization Webhook"
echo "═══════════════════════════════════════════════════════════════"

# Check if webhook already exists
EXISTING_HOOK=$(gh api "orgs/$ORG_NAME/hooks" --jq ".[] | select(.config.url==\"$WEBHOOK_URL\") | .id" 2>/dev/null || echo "")

if [[ -n "$EXISTING_HOOK" ]]; then
    warn "Webhook already exists (ID: $EXISTING_HOOK). Updating."
    gh api "orgs/$ORG_NAME/hooks/$EXISTING_HOOK" -X PATCH \
        -f "config[url]=$WEBHOOK_URL" \
        -f "config[content_type]=json" \
        -f "config[secret]=$WEBHOOK_SECRET" \
        --input - <<< '{"events":["workflow_job"],"active":true}' >/dev/null
else
    gh api "orgs/$ORG_NAME/hooks" -X POST \
        -f "config[url]=$WEBHOOK_URL" \
        -f "config[content_type]=json" \
        -f "config[secret]=$WEBHOOK_SECRET" \
        -f "name=web" \
        --input - <<< '{"events":["workflow_job"],"active":true}' >/dev/null
    log "Created GitHub org webhook for workflow_job events"
fi

# ─── DONE ────────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo " SETUP COMPLETE"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "  Webhook URL:  $WEBHOOK_URL"
echo "  ASG Name:     $ASG_NAME"
echo "  Instance:     $INSTANCE_TYPE (Arm64 Spot)"
echo "  Max runners:  $MAX_RUNNERS"
echo "  Cost:         \$0.035/hr ONLY when jobs run, \$0 when idle"
echo ""
echo "  To use in your workflows, set:"
echo ""
echo "    runs-on: [self-hosted, linux, arm64, fast]"
echo ""
echo "  To test, run:"
echo "    aws autoscaling set-desired-capacity \\"
echo "      --auto-scaling-group-name $ASG_NAME \\"
echo "      --desired-capacity 1 --region $AWS_REGION"
echo ""
echo "  To tear down everything:"
echo "    bash teardown.sh"
echo ""
