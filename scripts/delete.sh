#!/bin/bash
# delete.sh — drain ECS tasks, unmount EFS, terminate instances, then delete stack.
# Note: S3 backup bucket has DeletionPolicy:Retain and will NOT be deleted.
#       Delete it manually if no longer needed (see output at end of this script).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR/../.env" ] && source "$SCRIPT_DIR/../.env"

STACK=${1:-${STACK_NAME:-ecs-hello-world}}
REGION=${2:-${AWS_REGION:-us-east-1}}

# --- Check stack exists ---
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

# --- Step 1: Scale ECS service to 0 (drains ALB registrations before tasks stop) ---
CLUSTER=$(aws cloudformation describe-stack-resources \
  --stack-name "$STACK" \
  --query "StackResources[?ResourceType=='AWS::ECS::Cluster'].PhysicalResourceId" \
  --output text --region "$REGION" 2>/dev/null || echo "")

SERVICE=$(aws cloudformation describe-stack-resources \
  --stack-name "$STACK" \
  --query "StackResources[?ResourceType=='AWS::ECS::Service'].PhysicalResourceId" \
  --output text --region "$REGION" 2>/dev/null || echo "")

if [[ -n "$CLUSTER" && -n "$SERVICE" && "$SERVICE" != "None" ]]; then
  echo "=== Step 1: Draining ECS tasks ==="
  aws ecs update-service \
    --cluster "$CLUSTER" --service "$SERVICE" --desired-count 0 \
    --region "$REGION" > /dev/null
  echo "Waiting for tasks to stop ..."
  aws ecs wait services-stable \
    --cluster "$CLUSTER" --services "$SERVICE" \
    --region "$REGION" || true   # non-fatal — proceed even if wait times out
  echo "Tasks drained."
fi
echo ""

# --- Step 2: Unmount EFS on all instances before they terminate ---
# This is the critical step: EFS MountTargets cannot be deleted while NFS
# connections are active. If EC2 instances are terminated with EFS still mounted,
# the in-flight NFS connections prevent MountTarget deletion, which then blocks
# VPC cleanup (IGW detachment, security groups, subnets).
echo "=== Step 2: Unmounting EFS on all instances ==="
INSTANCE_ARNS=$(aws ecs list-container-instances \
  --cluster MyECSCluster --region "$REGION" \
  --query "containerInstanceArns[]" --output text 2>/dev/null || echo "")

if [[ -n "$INSTANCE_ARNS" && "$INSTANCE_ARNS" != "None" ]]; then
  INSTANCE_IDS=$(aws ecs describe-container-instances \
    --cluster MyECSCluster --region "$REGION" \
    --container-instances $INSTANCE_ARNS \
    --query "containerInstances[].ec2InstanceId" --output text)

  echo "Sending umount to: $INSTANCE_IDS"
  CMD_ID=$(aws ssm send-command \
    --instance-ids $INSTANCE_IDS \
    --document-name AWS-RunShellScript \
    --parameters 'commands=["umount /ecs/logs 2>/dev/null || true","systemctl stop ecs 2>/dev/null || true"]' \
    --comment "pre-delete EFS unmount" \
    --region "$REGION" \
    --query "Command.CommandId" --output text)

  echo -n "Waiting for umount"
  for i in $(seq 1 18); do   # 90s max
    sleep 5
    PENDING=$(aws ssm list-command-invocations \
      --command-id "$CMD_ID" --region "$REGION" \
      --query "CommandInvocations[?Status=='InProgress' || Status=='Pending'] | length(@)" \
      --output text 2>/dev/null || echo "0")
    echo -n "."
    [[ "$PENDING" == "0" ]] && break
  done
  echo " done."
else
  echo "No running instances found — skipping umount."
fi
echo ""

# --- Step 3: Scale ASG to 0 and wait for all instances to terminate ---
# Wait for actual EC2 termination (not just a sleep) so that EFS MountTargets
# have no remaining NFS clients when CloudFormation attempts to delete them.
ASG_NAME=$(aws cloudformation describe-stack-resources \
  --stack-name "$STACK" \
  --query "StackResources[?ResourceType=='AWS::AutoScaling::AutoScalingGroup'].PhysicalResourceId" \
  --output text --region "$REGION" 2>/dev/null || echo "")

if [[ -n "$ASG_NAME" && "$ASG_NAME" != "None" ]]; then
  echo "=== Step 3: Scaling ASG to 0 and waiting for instance termination ==="
  aws autoscaling update-auto-scaling-group \
    --auto-scaling-group-name "$ASG_NAME" \
    --min-size 0 --max-size 0 --desired-capacity 0 \
    --region "$REGION"

  echo -n "Waiting for all instances to terminate"
  for i in $(seq 1 36); do   # up to 3 minutes
    sleep 5
    COUNT=$(aws autoscaling describe-auto-scaling-groups \
      --auto-scaling-group-names "$ASG_NAME" \
      --region "$REGION" \
      --query "AutoScalingGroups[0].Instances | length(@)" \
      --output text 2>/dev/null || echo "0")
    echo -n "."
    [[ "$COUNT" == "0" ]] && break
  done
  echo " done."
fi
echo ""

# --- Step 4: Delete the stack ---
echo "=== Step 4: Deleting stack $STACK ==="
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
    echo ""
    echo "Resources still blocking deletion:"
    aws cloudformation describe-stack-resources \
      --stack-name "$STACK" --region "$REGION" \
      --query "StackResources[?ResourceStatus=='DELETE_FAILED'].[ResourceType,LogicalResourceId,ResourceStatusReason]" \
      --output table
    exit 1
  fi
  sleep 10
done

# --- Remind about retained S3 bucket ---
echo ""
echo "Note: S3 backup bucket was retained. Delete manually if no longer needed:"
BUCKET=$(aws s3 ls 2>/dev/null | grep "${STACK}" | awk '{print $3}' || echo "")
if [[ -n "$BUCKET" ]]; then
  echo "  aws s3 rb s3://$BUCKET --force --region $REGION"
fi
