#!/usr/bin/env bash
set -euo pipefail

# Required: set via environment or CLI args
INSTANCE_ID="${INSTANCE_ID:?Set INSTANCE_ID (e.g. INSTANCE_ID=i-xxx)}"
SECRET_ARN="${SECRET_ARN:?Set SECRET_ARN (e.g. SECRET_ARN=arn:aws:secretsmanager:...)}"
REGION="${REGION:-us-east-1}"

LOCAL_AUTH_FILE="$HOME/.hermes/auth.json"
REMOTE_AUTH_FILE="/home/hermes/.hermes/auth.json"

if [[ ! -f "$LOCAL_AUTH_FILE" ]]; then
  echo "ERROR: $LOCAL_AUTH_FILE not found. Run 'hermes auth add nous' first."
  exit 1
fi

echo "Updating Secrets Manager secret with local auth.json..."
aws secretsmanager put-secret-value \
  --secret-id "$SECRET_ARN" \
  --secret-string "file://$LOCAL_AUTH_FILE" \
  --region "$REGION"
echo "Secrets Manager updated."

echo "Having instance pull updated auth.json from Secrets Manager..."
CMD_ID=$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --region "$REGION" \
  --document-name AWS-RunShellScript \
  --parameters "commands=[\"aws secretsmanager get-secret-value --secret-id $SECRET_ARN --query SecretString --output text > $REMOTE_AUTH_FILE && chown hermes:hermes $REMOTE_AUTH_FILE && chmod 600 $REMOTE_AUTH_FILE && systemctl restart hermes.service\"]" \
  --query 'Command.CommandId' --output text)

echo "Waiting for command $CMD_ID..."
for i in {1..30}; do
  sleep 2
  STATUS=$(aws ssm get-command-invocation \
    --command-id "$CMD_ID" \
    --instance-id "$INSTANCE_ID" \
    --region "$REGION" \
    --query 'CommandInvocation.Status' --output text)
  if [[ "$STATUS" == "Success" ]]; then
    echo "Done. Instance updated and hermes.service restarted."
    exit 0
  elif [[ "$STATUS" =~ (Failed|Cancelled|TimedOut) ]]; then
    echo "ERROR: Command $STATUS"
    aws ssm get-command-invocation \
      --command-id "$CMD_ID" \
      --instance-id "$INSTANCE_ID" \
      --region "$REGION" \
      --query 'CommandInvocation.StandardErrorContent' --output text
    exit 1
  fi
done

echo "ERROR: Command timed out waiting for response"
exit 1
