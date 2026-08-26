#!/usr/bin/env bash
set -euo pipefail

SECRET_ARN="${SECRET_ARN:?Set SECRET_ARN}"
AUTH_FILE="/home/hermes/.hermes/auth.json"

if [[ ! -f "$AUTH_FILE" ]]; then
  echo "ERROR: $AUTH_FILE not found. Run 'hermes auth add nous' first."
  exit 1
fi

echo "Updating Secrets Manager secret with current auth.json..."
aws secretsmanager put-secret-value \
  --secret-id "$SECRET_ARN" \
  --secret-string "file://$AUTH_FILE" \
  --region us-east-1

echo "Done. Future instances will use these credentials."
