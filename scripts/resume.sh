#!/bin/bash
# resume.sh — bring the stack back up and restore records.json from S3
# Suspend with: ./scripts/suspend.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

[ -f .env ] && source .env

STACK=${1:-${STACK_NAME:-ecs-hello-world}}
REGION=${2:-${AWS_REGION:-us-east-1}}
APP_IMAGE=${3:-${APP_IMAGE:-vineetma/ecs-hello-world:1.4}}

# --- Step 1: Bring stack up ---
echo "=== Step 1: Resuming stack $STACK ==="
aws cloudformation deploy \
  --template-file "$REPO_ROOT/cf/ecs-ec2-multi-node-cf.yaml" \
  --stack-name "$STACK" \
  --region "$REGION" \
  --parameter-overrides AppImage="$APP_IMAGE" Suspended=false EFSEnabled=true \
  --capabilities CAPABILITY_NAMED_IAM
echo ""

# --- Step 2: Mount EFS and start ECS on all instances ---
# mount-efs.sh discovers instances via ASG (works even while ECS is still masked),
# waits for SSM agent readiness, mounts EFS, and starts ECS.
# This must complete before restoring records.json — otherwise the restore
# may write to local disk instead of EFS.
echo "=== Step 2: Mounting EFS and starting ECS ==="
"$SCRIPT_DIR/mount-efs.sh" "$STACK" "$REGION"
echo ""

# --- Step 3: Wait for an ECS instance to register (ECS was just started by mount-efs.sh) ---
echo "=== Step 3: Waiting for ECS instance to register ==="
INSTANCE_ID=""
for i in $(seq 1 12); do  # up to 2 minutes
  INSTANCE_ARN=$(aws ecs list-container-instances \
    --cluster MyECSCluster --region "$REGION" \
    --query "containerInstanceArns[0]" --output text 2>/dev/null || echo "None")

  if [[ "$INSTANCE_ARN" != "None" && -n "$INSTANCE_ARN" ]]; then
    INSTANCE_ID=$(aws ecs describe-container-instances \
      --cluster MyECSCluster \
      --container-instances "$INSTANCE_ARN" \
      --query "containerInstances[0].ec2InstanceId" \
      --output text --region "$REGION")
    echo "Instance $INSTANCE_ID registered."
    break
  fi
  echo "  Attempt $i/12: waiting for instance ..."
  sleep 10
done

if [[ -z "$INSTANCE_ID" ]]; then
  echo "WARNING: No ECS instance registered after timeout — skipping restore."
  echo "EFS is mounted. Run resume.sh again to retry the restore."
  exit 1
fi

# --- Step 4: Restore records.json from S3 ---
BUCKET=$(aws cloudformation describe-stacks \
  --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='BackupBucketName'].OutputValue" \
  --output text --region "$REGION")

echo ""
echo "=== Step 4: Restoring records.json from s3://$BUCKET/records.json ==="

CMD_ID=$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --parameters "commands=[\"mkdir -p /ecs/logs/data && aws s3 cp s3://${BUCKET}/records.json /ecs/logs/data/records.json && echo Restored || echo No backup found - starting fresh\"]" \
  --query "Command.CommandId" --output text --region "$REGION")

echo -n "Waiting for restore"
for i in $(seq 1 24); do
  sleep 5
  STATUS=$(aws ssm get-command-invocation \
    --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
    --query "Status" --output text --region "$REGION" 2>/dev/null || echo "Pending")
  echo -n "."
  if [[ "$STATUS" == "Success" || "$STATUS" == "Failed" || "$STATUS" == "Cancelled" ]]; then
    echo " $STATUS"
    break
  fi
done

# --- Print URL ---
echo ""
echo "=== Stack is live ==="
ALB_URL=$(aws cloudformation describe-stacks \
  --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='ALBDNSName'].OutputValue" \
  --output text --region "$REGION")
echo "$ALB_URL"
