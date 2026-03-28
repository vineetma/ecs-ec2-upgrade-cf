#!/bin/bash
# delete.sh — drain ECS tasks and delete the full stack
# Note: S3 backup bucket has DeletionPolicy:Retain and will NOT be deleted.
#       Delete it manually if no longer needed (see output at end of this script).

set -euo pipefail

[ -f .env ] && source .env

STACK=${STACK_NAME:-hello-world-test}
REGION=${AWS_REGION:-us-east-1}

# Check stack exists
STATUS=$(aws cloudformation describe-stacks \
  --stack-name "$STACK" \
  --query "Stacks[0].StackStatus" \
  --output text --region "$REGION" 2>/dev/null || echo "DOES_NOT_EXIST")

if [[ "$STATUS" == "DOES_NOT_EXIST" ]]; then
  echo "Stack '$STACK' does not exist — nothing to delete."
  exit 0
fi

echo "Stack '$STACK' status: $STATUS"
echo ""

# Scale ECS service to 0 before deleting — avoids the 300s ALB deregistration
# drain that causes ECS service DELETE_FAILED when tasks are still running.
CLUSTER=$(aws cloudformation describe-stack-resources \
  --stack-name "$STACK" \
  --query "StackResources[?ResourceType=='AWS::ECS::Cluster'].PhysicalResourceId" \
  --output text --region "$REGION" 2>/dev/null || echo "")

SERVICE=$(aws cloudformation describe-stack-resources \
  --stack-name "$STACK" \
  --query "StackResources[?ResourceType=='AWS::ECS::Service'].PhysicalResourceId" \
  --output text --region "$REGION" 2>/dev/null || echo "")

if [[ -n "$CLUSTER" && -n "$SERVICE" && "$SERVICE" != "None" ]]; then
  echo "Scaling ECS service to 0 to drain tasks ..."
  aws ecs update-service \
    --cluster "$CLUSTER" --service "$SERVICE" --desired-count 0 \
    --region "$REGION" > /dev/null
  echo "Waiting 30s for tasks to drain ..."
  sleep 30
fi

echo "=== Deleting stack $STACK ==="
aws cloudformation delete-stack --stack-name "$STACK" --region "$REGION"

echo -n "Waiting for deletion"
while true; do
  STATUS=$(aws cloudformation describe-stacks \
    --stack-name "$STACK" \
    --query "Stacks[0].StackStatus" \
    --output text --region "$REGION" 2>/dev/null || echo "DOES_NOT_EXIST")
  echo -n "."
  if [[ "$STATUS" == "DOES_NOT_EXIST" ]]; then
    echo " Done."
    break
  fi
  if [[ "$STATUS" == "DELETE_FAILED" ]]; then
    echo " DELETE_FAILED"
    echo "Check the AWS console for resources that blocked deletion."
    exit 1
  fi
  sleep 10
done

# Remind about retained S3 bucket
echo ""
echo "Note: S3 backup bucket was retained. Delete manually if no longer needed:"
BUCKET=$(aws s3 ls 2>/dev/null | grep "${STACK}-backup" | awk '{print $3}' || echo "")
if [[ -n "$BUCKET" ]]; then
  echo "  aws s3 rb s3://$BUCKET --force --region $REGION"
fi
