#!/bin/bash
# suspend.sh — back up records.json to S3, then scale down EC2 and remove ALB (zero cost)
# Resume with: ./scripts/resume.sh

set -euo pipefail

[ -f .env ] && source .env

STACK=${1:-${STACK_NAME:-hello-world-test}}
REGION=${2:-${AWS_REGION:-us-east-1}}
APP_IMAGE=${3:-${APP_IMAGE:-vineetma/ecs-hello-world:1.4}}

# --- Backup records.json to S3 ---
echo "=== Backing up records.json to S3 ==="

BUCKET=$(aws cloudformation describe-stacks \
  --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='BackupBucketName'].OutputValue" \
  --output text --region "$REGION")

INSTANCE_ARN=$(aws ecs list-container-instances \
  --cluster MyECSCluster --region "$REGION" \
  --query "containerInstanceArns[0]" --output text 2>/dev/null || echo "None")

if [[ "$INSTANCE_ARN" == "None" || -z "$INSTANCE_ARN" ]]; then
  echo "No running instances — skipping backup."
else
  INSTANCE_ID=$(aws ecs describe-container-instances \
    --cluster MyECSCluster \
    --container-instances "$INSTANCE_ARN" \
    --query "containerInstances[0].ec2InstanceId" \
    --output text --region "$REGION")

  echo "Backing up from $INSTANCE_ID to s3://$BUCKET/records.json ..."

  CMD_ID=$(aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name AWS-RunShellScript \
    --parameters "commands=[\"if [ -f /ecs/logs/data/records.json ]; then aws s3 cp /ecs/logs/data/records.json s3://${BUCKET}/records.json && echo Backed up; else echo No data file found; fi\"]" \
    --query "Command.CommandId" --output text --region "$REGION")

  echo -n "Waiting for backup"
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
fi

# --- Suspend stack ---
echo ""
echo "=== Suspending stack $STACK ==="
aws cloudformation deploy \
  --template-file cf/ecs-ec2-multi-node-cf.yaml \
  --stack-name "$STACK" \
  --region "$REGION" \
  --parameter-overrides AppImage="$APP_IMAGE" Suspended=true EFSEnabled=false \
  --capabilities CAPABILITY_NAMED_IAM

echo "Done. EC2 instances and ALB removed. Running cost: \$0."
