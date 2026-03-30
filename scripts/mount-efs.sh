#!/bin/bash
# mount-efs.sh — verify EFS is mounted on all ECS instances; mount if not.
# Discovers instances via ASG (not ECS) so it works even when ECS is still masked.
# Runs the check+mount via SSM send-command (no SSH needed).
# Usage: ./scripts/mount-efs.sh [stack-name] [region]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR/../.env" ] && source "$SCRIPT_DIR/../.env"

STACK=${1:-${STACK_NAME:-ecs-hello-world}}
REGION=${2:-${AWS_REGION:-us-east-1}}

# --- Resolve EFS filesystem ID from stack outputs ---
EFS_ID=$(aws cloudformation describe-stacks \
  --stack-name "$STACK" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='EFSFileSystemId'].OutputValue" \
  --output text)

if [[ -z "$EFS_ID" || "$EFS_ID" == "None" ]]; then
  echo "ERROR: EFSFileSystemId not in stack outputs — is EFSEnabled=true?" >&2
  exit 1
fi
echo "EFS filesystem: $EFS_ID"

# --- Resolve EC2 instance IDs from the ASG ---
# Uses ASG instead of ECS because ECS is masked at boot and may not have any
# registered instances yet when this script is called during resume.
ASG_NAME=$(aws cloudformation describe-stack-resources \
  --stack-name "$STACK" --region "$REGION" \
  --query "StackResources[?ResourceType=='AWS::AutoScaling::AutoScalingGroup'].PhysicalResourceId" \
  --output text)

if [[ -z "$ASG_NAME" || "$ASG_NAME" == "None" ]]; then
  echo "ERROR: Could not find ASG in stack resources." >&2
  exit 1
fi

echo -n "Waiting for ASG instances to be InService"
INSTANCE_IDS=""
for i in $(seq 1 24); do  # up to 2 minutes
  INSTANCE_IDS=$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$ASG_NAME" --region "$REGION" \
    --query "AutoScalingGroups[0].Instances[?LifecycleState=='InService'].InstanceId" \
    --output text)
  [[ -n "$INSTANCE_IDS" ]] && break
  echo -n "."
  sleep 5
done
echo ""

if [[ -z "$INSTANCE_IDS" ]]; then
  echo "ERROR: No InService instances in ASG after timeout." >&2
  exit 1
fi
echo "Instances: $INSTANCE_IDS"

# --- Wait for SSM agent to be ready on all instances ---
# Instances need ~60s after boot before SSM agent registers and can accept commands.
echo -n "Waiting for SSM agent on all instances"
for IIDS in $INSTANCE_IDS; do
  for i in $(seq 1 24); do  # up to 2 minutes per instance
    READY=$(aws ssm describe-instance-information \
      --filters "Key=InstanceIds,Values=$IIDS" --region "$REGION" \
      --query "InstanceInformationList | length(@)" \
      --output text 2>/dev/null || echo "0")
    [[ "$READY" -gt 0 ]] && break
    echo -n "."
    sleep 5
  done
  READY=$(aws ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=$IIDS" --region "$REGION" \
    --query "InstanceInformationList | length(@)" \
    --output text 2>/dev/null || echo "0")
  if [[ "$READY" -eq 0 ]]; then
    echo ""
    echo "ERROR: SSM agent not ready on $IIDS after timeout." >&2
    exit 1
  fi
done
echo " ready."
echo ""

# --- Build the remote script and base64-encode it ---
# Base64 avoids all JSON/shell escaping issues and removes the python3 dependency.
# The SSM command decodes and pipes to bash on the EC2 instance.
REMOTE_SCRIPT="set -e
MOUNT_POINT=/ecs/logs
EFS_ID=${EFS_ID}

if ! rpm -q amazon-efs-utils &>/dev/null; then
  echo '[install] amazon-efs-utils not found — installing...'
  yum install -y amazon-efs-utils
else
  echo '[install] amazon-efs-utils already installed'
fi

if grep -qE '(^|[[:space:]])${EFS_ID}([[:space:]]|\$)' /etc/fstab; then
  echo '[fstab] entry already present'
else
  echo '[fstab] adding entry for ${EFS_ID}'
  echo \"${EFS_ID}:/ \${MOUNT_POINT} efs defaults,_netdev,nofail 0 0\" >> /etc/fstab
fi

if mount | grep -q \" \${MOUNT_POINT} \"; then
  echo '[mount] EFS already mounted at '\${MOUNT_POINT}
else
  echo '[mount] not mounted — running mount -a ...'
  mount -a
  if mount | grep -q \" \${MOUNT_POINT} \"; then
    echo '[mount] SUCCESS — EFS mounted at '\${MOUNT_POINT}
  else
    echo '[mount] FAILED — check EFS mount target availability and security groups' >&2
    exit 1
  fi
fi

mkdir -p \${MOUNT_POINT}/nginx \${MOUNT_POINT}/data
echo '[dirs] '\${MOUNT_POINT}'/nginx and '\${MOUNT_POINT}'/data are present'

ECS_STATE=\$(systemctl is-active ecs 2>/dev/null || true)
if [[ \"\${ECS_STATE}\" != \"active\" ]]; then
  echo '[ecs] ECS is not active (state: '\${ECS_STATE}') — unmasking and starting...'
  systemctl unmask ecs
  systemctl start ecs
  echo '[ecs] ECS started'
else
  echo '[ecs] ECS already active'
fi"

ENCODED=$(printf '%s' "$REMOTE_SCRIPT" | base64 | tr -d '\n')

# --- Fire SSM send-command on all instances ---
echo "=== Sending mount-efs command to: $INSTANCE_IDS ==="
CMD_ID=$(aws ssm send-command \
  --instance-ids $INSTANCE_IDS \
  --document-name AWS-RunShellScript \
  --parameters "commands=[\"echo $ENCODED | base64 -d | bash\"]" \
  --comment "mount-efs" \
  --region "$REGION" \
  --query "Command.CommandId" --output text)

echo "Command ID: $CMD_ID"
echo ""

# --- Poll until all invocations complete ---
echo -n "Waiting for completion"
for i in $(seq 1 36); do  # up to 3 minutes
  sleep 5
  PENDING=$(aws ssm list-command-invocations \
    --command-id "$CMD_ID" --region "$REGION" \
    --query "CommandInvocations[?Status=='InProgress' || Status=='Pending'] | length(@)" \
    --output text)
  echo -n "."
  [[ "$PENDING" == "0" ]] && break
done
echo ""
echo ""

# --- Print per-instance results ---
OVERALL=0
for IIDS in $INSTANCE_IDS; do
  STATUS=$(aws ssm get-command-invocation \
    --command-id "$CMD_ID" --instance-id "$IIDS" \
    --region "$REGION" --query "Status" --output text 2>/dev/null || echo "Unknown")
  OUTPUT=$(aws ssm get-command-invocation \
    --command-id "$CMD_ID" --instance-id "$IIDS" \
    --region "$REGION" --query "StandardOutputContent" --output text 2>/dev/null || echo "")
  ERROR=$(aws ssm get-command-invocation \
    --command-id "$CMD_ID" --instance-id "$IIDS" \
    --region "$REGION" --query "StandardErrorContent" --output text 2>/dev/null || echo "")

  echo "--- $IIDS: $STATUS ---"
  [[ -n "$OUTPUT" ]] && echo "$OUTPUT"
  [[ -n "$ERROR" ]] && echo "STDERR: $ERROR"
  echo ""

  [[ "$STATUS" != "Success" ]] && OVERALL=1
done

if [[ "$OVERALL" -ne 0 ]]; then
  echo "=== One or more instances FAILED — check output above ===" >&2
  exit 1
fi

echo "=== All instances: EFS mounted and ECS running ==="
echo ""

# --- Force restart ECS tasks so they bind to EFS, not local disk ---
# Tasks that started before EFS was mounted have their /data bind-mount pointing
# at the local-disk path. Fixing the host mount does not fix already-running
# containers — they must be restarted to pick up the EFS-backed path.
CLUSTER=$(aws cloudformation describe-stack-resources \
  --stack-name "$STACK" --region "$REGION" \
  --query "StackResources[?ResourceType=='AWS::ECS::Cluster'].PhysicalResourceId" \
  --output text 2>/dev/null || echo "")

SERVICE=$(aws cloudformation describe-stack-resources \
  --stack-name "$STACK" --region "$REGION" \
  --query "StackResources[?ResourceType=='AWS::ECS::Service'].PhysicalResourceId" \
  --output text 2>/dev/null || echo "")

if [[ -n "$CLUSTER" && -n "$SERVICE" && "$SERVICE" != "None" ]]; then
  echo "=== Restarting ECS tasks to rebind /data to EFS ==="
  aws ecs update-service \
    --cluster "$CLUSTER" --service "$SERVICE" \
    --force-new-deployment \
    --region "$REGION" > /dev/null
  echo "Waiting for service to stabilize ..."
  aws ecs wait services-stable \
    --cluster "$CLUSTER" --services "$SERVICE" \
    --region "$REGION"
  echo "Tasks restarted — /data is now backed by EFS."
else
  echo "No active ECS service found — skipping task restart."
fi
