#!/bin/bash
# poll-health.sh — run this in a second terminal during AMI upgrade
# Hits /api/info every 2s and prints timestamp, HTTP status, and which instance served it.
# Any gap or non-200 = downtime.

[ -f .env ] && source .env

STACK=${1:-${STACK_NAME:-ecs-hello-world}}
REGION=${2:-${AWS_REGION:-us-east-1}}

ALB_URL=$(aws cloudformation describe-stacks \
  --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='ALBDNSName'].OutputValue" \
  --output text --region "$REGION")

if [[ -z "$ALB_URL" ]]; then
  echo "ERROR: could not get ALBDNSName from stack $STACK"
  exit 1
fi

echo "Polling $ALB_URL/api/info every 2s  (Ctrl-C to stop)"
echo "-------------------------------------------------------"

while true; do
  RESPONSE=$(curl -s -o /tmp/poll_body.json -w "%{http_code}" \
    --max-time 5 "$ALB_URL/api/info" 2>/dev/null)
  TS=$(date '+%H:%M:%S')

  if [[ "$RESPONSE" == "200" ]]; then
    INSTANCE=$(grep -o '"instanceId":"[^"]*"' /tmp/poll_body.json | cut -d'"' -f4)
    AZ=$(grep -o '"az":"[^"]*"' /tmp/poll_body.json | cut -d'"' -f4)
    echo "$TS  OK ($RESPONSE)  instance=$INSTANCE  az=$AZ"
  else
    echo "$TS  *** FAIL ($RESPONSE) ***"
  fi

  sleep 2
done
