#!/usr/bin/env bash
set -euo pipefail

INSTANCE_ID="${INSTANCE_ID:?Set INSTANCE_ID}"
REGION="us-east-1"
SECRET_ARN="${SECRET_ARN:?Set SECRET_ARN}"
REMOTE_AUTH_FILE="/home/hermes/.hermes/auth.json"

echo "Fetching auth.json from instance $INSTANCE_ID..."
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --region "$REGION" \
  --document-name AWS-RunShellScript \
  --parameters "commands=[\"cat $REMOTE_AUTH_FILE\"]" \
  --query 'Command.CommandId' --output text > "$TMP.cmd_id"

CMD_ID=$(cat "$TMP.cmd_id")
echo "Waiting for command $CMD_ID..."

for i in {1..30}; do
  sleep 2
  STATUS=$(aws ssm get-command-invocation \
    --command-id "$CMD_ID" \
    --instance-id "$INSTANCE_ID" \
    --region "$REGION" \
    --query 'CommandInvocation.Status' --output text)
  if [[ "$STATUS" == "Success" ]]; then
    aws ssm get-command-invocation \
      --command-id "$CMD_ID" \
      --instance-id "$INSTANCE_ID" \
      --region "$REGION" \
      --query 'StandardOutputContent' --output text > "$TMP"
    break
  elif [[ "$STATUS" =~ (Failed|Cancelled|TimedOut) ]]; then
    echo "ERROR: Command $STATUS"
    exit 1
  fi
done

if [[ ! -s "$TMP" ]]; then
  echo "ERROR: Could not fetch auth.json from instance"
  exit 1
fi

echo "Updating Secrets Manager secret..."
aws secretsmanager put-secret-value \
  --secret-id "$SECRET_ARN" \
  --secret-string "file://$TMP" \
  --region "$REGION"

echo "Done. Future instances will use these credentials."
