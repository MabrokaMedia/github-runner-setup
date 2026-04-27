#!/bin/bash
# Build a pre-baked AMI with the GitHub Actions runner binary + deps pre-installed.
# Saves ~60-90s per runner spawn (~$11/mo at current job volumes).
#
# Usage:
#   bash build-ami.sh                   # uses defaults
#   bash build-ami.sh us-east-1 c7g.large
#
# Output: prints the new AMI ID. Update the launch template's ImageId to use it.

set -euo pipefail

AWS_REGION="${1:-us-east-1}"
BUILDER_TYPE="${2:-c7g.large}"

PREFIX="gh-runner"
SG_NAME="${PREFIX}-sg"
INSTANCE_PROFILE="${PREFIX}-ec2-role"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# ─── Look up prerequisites ───────────────────────────────────────────────────
BASE_AMI=$(aws ec2 describe-images --region "$AWS_REGION" --owners amazon \
    --filters "Name=name,Values=al2023-ami-2023*-arm64" "Name=state,Values=available" \
    --query "sort_by(Images, &CreationDate)[-1].ImageId" --output text)
[[ -z "$BASE_AMI" || "$BASE_AMI" == "None" ]] && err "Could not find AL2023 ARM64 AMI"
log "base AMI: $BASE_AMI"

SG=$(aws ec2 describe-security-groups --region "$AWS_REGION" \
    --filters "Name=group-name,Values=$SG_NAME" \
    --query "SecurityGroups[0].GroupId" --output text)
[[ -z "$SG" || "$SG" == "None" ]] && err "Security group $SG_NAME not found — run setup.sh first"
log "SG: $SG"

PREFERRED_AZ="${AWS_REGION}a"
SUBNET=$(aws ec2 describe-subnets --region "$AWS_REGION" \
    --filters "Name=default-for-az,Values=true" "Name=availability-zone,Values=$PREFERRED_AZ" \
    --query "Subnets[0].SubnetId" --output text)
log "subnet: $SUBNET"

# ─── Builder user-data: install everything, then shut down ───────────────────
USER_DATA=$(cat <<'UD'
#!/bin/bash
set -euo pipefail
exec > /var/log/ami-builder.log 2>&1

echo "=== installing deps ==="
dnf update -y
# `lld` is the LLVM linker; rust workflows that opt in via
# `RUSTFLAGS=-C link-arg=-fuse-ld=lld` save ~1-2 min on the link
# phase of large release builds (e.g. cargo lambda build with 23+
# release-mode binaries). Baking it in removes the per-job
# `dnf install lld` overhead and makes the linker reliably present
# on every fresh runner spawn.
dnf install -y git docker jq libicu tar gzip zstd lld

echo "=== docker ==="
systemctl enable docker
useradd -m runner || true
usermod -aG docker runner

echo "=== runner binary ==="
mkdir -p /home/runner/actions-runner
cd /home/runner/actions-runner
RUNNER_VERSION=$(curl -s https://api.github.com/repos/actions/runner/releases/latest | jq -r .tag_name | tr -d 'v')
curl -sL "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-arm64-${RUNNER_VERSION}.tar.gz" -o runner.tar.gz
tar xzf runner.tar.gz
rm runner.tar.gz
echo "$RUNNER_VERSION" > /etc/ami-runner-version

echo "=== /opt/rust stub ==="
mkdir -p /opt/rust

chown -R runner:runner /home/runner /opt/rust

echo "=== clean ==="
dnf clean all
rm -rf /tmp/* /var/tmp/*

touch /var/log/ami-builder-done
shutdown -h +1 "AMI builder done"
UD
)
USER_DATA_B64=$(echo "$USER_DATA" | base64 -w 0)

# ─── Launch builder ──────────────────────────────────────────────────────────
log "launching builder ($BUILDER_TYPE)..."
BUILDER_ID=$(aws ec2 run-instances --region "$AWS_REGION" \
    --image-id "$BASE_AMI" \
    --instance-type "$BUILDER_TYPE" \
    --iam-instance-profile "Name=$INSTANCE_PROFILE" \
    --security-group-ids "$SG" \
    --subnet-id "$SUBNET" \
    --user-data "$USER_DATA_B64" \
    --instance-initiated-shutdown-behavior stop \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=gh-runner-ami-builder},{Key=Purpose,Value=ami-builder}]' \
    --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":20,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
    --query 'Instances[0].InstanceId' --output text)
log "builder: $BUILDER_ID"

# ─── Wait for install + shutdown ─────────────────────────────────────────────
log "waiting for builder to stop (install + shutdown)..."
for i in $(seq 1 60); do
    STATE=$(aws ec2 describe-instances --region "$AWS_REGION" --instance-ids "$BUILDER_ID" \
        --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null)
    [[ "$STATE" == "stopped" ]] && break
    sleep 20
done
[[ "$STATE" != "stopped" ]] && err "builder did not stop in time"
log "builder stopped"

# ─── Snapshot + wait ─────────────────────────────────────────────────────────
AMI_NAME="gh-runner-prebaked-$(date +%Y%m%d-%H%M%S)"
AMI_ID=$(aws ec2 create-image --region "$AWS_REGION" \
    --instance-id "$BUILDER_ID" \
    --name "$AMI_NAME" \
    --description "Pre-baked GH Actions runner AMI (runner binary + deps)" \
    --no-reboot \
    --tag-specifications 'ResourceType=image,Tags=[{Key=Purpose,Value=github-runner-ami}]' \
    --query 'ImageId' --output text)
log "creating AMI: $AMI_ID ($AMI_NAME)"

for i in $(seq 1 40); do
    STATE=$(aws ec2 describe-images --region "$AWS_REGION" --image-ids "$AMI_ID" \
        --query 'Images[0].State' --output text 2>/dev/null)
    [[ "$STATE" == "available" ]] && break
    sleep 20
done
[[ "$STATE" != "available" ]] && err "AMI did not become available"
log "AMI available"

# ─── Cleanup builder ─────────────────────────────────────────────────────────
aws ec2 terminate-instances --region "$AWS_REGION" --instance-ids "$BUILDER_ID" >/dev/null
log "builder terminated"

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo " NEW AMI: $AMI_ID"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "  To use this AMI, create a new launch template version with"
echo "  ImageId=$AMI_ID and a simplified user-data that assumes the"
echo "  runner binary is already at /home/runner/actions-runner/."
echo ""
echo "  Rebuild monthly to pick up newer AL2023 + runner versions."
