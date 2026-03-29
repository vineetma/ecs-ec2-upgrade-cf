#!/bin/bash
# deploy.sh — create a fresh ECS stack (exits if stack already exists)
# Delete with: ./scripts/delete.sh

set -euo pipefail

[ -f .env ] && source .env

STACK=${STACK_NAME:-ecs-hello-world}
REGION=${AWS_REGION:-us-east-1}
APP_IMAGE=${APP_IMAGE:-vineetma/ecs-hello-world:1.4}
AMI_ID=${AMI_ID:-ami-0dc67873410203528}

# Check if stack already exists
STATUS=$(aws cloudformation describe-stacks \
  --stack-name "$STACK" \
  --query "Stacks[0].StackStatus" \
  --output text --region "$REGION" 2>/dev/null || echo "DOES_NOT_EXIST")

if [[ "$STATUS" != "DOES_NOT_EXIST" ]]; then
  echo "Stack '$STACK' already exists (status: $STATUS)."
  echo "To update it, use: update-ami.sh, resume.sh, or suspend.sh"
  echo "To delete it first: ./scripts/delete.sh"
  exit 1
fi

echo "=== Creating stack: $STACK ==="
echo "  Region    : $REGION"
echo "  AMI       : $AMI_ID"
echo "  App image : $APP_IMAGE"
echo ""

aws cloudformation deploy \
  --template-file cf/ecs-ec2-multi-node-cf.yaml \
  --stack-name "$STACK" \
  --region "$REGION" \
  --parameter-overrides \
      AppImage="$APP_IMAGE" \
      AmiId="$AMI_ID" \
      Suspended=false \
      EFSEnabled=true \
  --capabilities CAPABILITY_NAMED_IAM

echo ""
echo "=== Stack is live ==="
aws cloudformation describe-stacks \
  --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='ALBDNSName'].OutputValue" \
  --output text --region "$REGION"
