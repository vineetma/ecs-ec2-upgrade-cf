#!/bin/bash
# update-ami.sh — trigger a rolling AMI upgrade on the ECS cluster ASG
#
# Usage:
#   ./scripts/update-ami.sh <ami-id>
#
# Known AMIs (ECS-optimized AL2, us-east-1):
#   ami-0dc67873410203528  amzn2-ami-ecs-hvm-2.0.20240328  (oldest — starting point)
#   ami-021fe45d6043e82c8  amzn2-ami-ecs-hvm-2.0.20240409
#   ami-057f57c2fcd14e5f4  amzn2-ami-ecs-hvm-2.0.20240424
#   ami-0cf60a53ad9cf9e40  amzn2-ami-ecs-hvm-2.0.20240515
#   ami-06cc69030d77088a1  amzn2-ami-ecs-hvm-2.0.20260226
#   ami-0605df8f00118a0df  amzn2-ami-ecs-hvm-2.0.20260307
#   ami-07bb74bad4a7a0b7a  amzn2-ami-ecs-hvm-2.0.20260323  (latest — upgrade target)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

[ -f .env ] && source .env

AMI_ID=${1:-}
STACK=${2:-${STACK_NAME:-ecs-hello-world}}
REGION=${3:-${AWS_REGION:-us-east-1}}
APP_IMAGE=${4:-${APP_IMAGE:-vineetma/ecs-hello-world:1.4}}

if [[ -z "$AMI_ID" ]]; then
  echo "Usage: ./scripts/update-ami.sh <ami-id> [stack-name] [region] [app-image]"
  echo ""
  echo "Known AMIs (ECS-optimized AL2, us-east-1):"
  echo "  ami-0dc67873410203528  2.0.20240328  (oldest — starting point)"
  echo "  ami-021fe45d6043e82c8  2.0.20240409"
  echo "  ami-057f57c2fcd14e5f4  2.0.20240424"
  echo "  ami-0cf60a53ad9cf9e40  2.0.20240515"
  echo "  ami-06cc69030d77088a1  2.0.20260226"
  echo "  ami-0605df8f00118a0df  2.0.20260307"
  echo "  ami-07bb74bad4a7a0b7a  2.0.20260323  (latest — upgrade target)"
  exit 1
fi

# Show current AMI from stack parameters
CURRENT_AMI=$(aws cloudformation describe-stacks \
  --stack-name "$STACK" \
  --query "Stacks[0].Parameters[?ParameterKey=='AmiId'].ParameterValue" \
  --output text --region "$REGION" 2>/dev/null || echo "unknown")

echo "Current AMI : $CURRENT_AMI"
echo "Target AMI  : $AMI_ID"
echo ""

if [[ "$CURRENT_AMI" == "$AMI_ID" ]]; then
  echo "Target AMI is already deployed — nothing to do."
  exit 0
fi

echo "=== Deploying AMI update to stack $STACK ==="
echo "ASG will replace one instance at a time (rolling update)."
echo "Run ./scripts/poll-health.sh in a second terminal to monitor for downtime."
echo ""

aws cloudformation deploy \
  --template-file "$REPO_ROOT/cf/ecs-ec2-multi-node-cf.yaml" \
  --stack-name "$STACK" \
  --region "$REGION" \
  --parameter-overrides \
      AppImage="$APP_IMAGE" \
      AmiId="$AMI_ID" \
      Suspended=false \
      EFSEnabled=true \
  --capabilities CAPABILITY_NAMED_IAM

echo ""
echo "=== Verifying instances are on new AMI ==="
aws ec2 describe-instances \
  --filters \
    "Name=tag:aws:cloudformation:stack-name,Values=$STACK" \
    "Name=instance-state-name,Values=running" \
  --query "Reservations[*].Instances[*].{Id:InstanceId,AMI:ImageId,AZ:Placement.AvailabilityZone}" \
  --output table --region "$REGION"
