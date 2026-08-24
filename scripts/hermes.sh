#!/usr/bin/env bash
set -euo pipefail

# Point these at your stack's instance. Get the id with:
#   aws cloudformation describe-stacks --stack-name hermes-agent \
#     --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" --output text
INSTANCE_ID="${HERMES_INSTANCE_ID:?Set HERMES_INSTANCE_ID to your EC2 instance id}"
REGION="${HERMES_AWS_REGION:-us-east-1}"

usage() {
  cat <<EOF
Usage: $(basename "$0") <command>

Commands:
  start     Start the Hermes EC2 instance and verify the service is running
  stop      Gracefully stop the Hermes service, then stop the instance
  status    Check if the instance is running and show the Hermes service status
  ssh       Open an interactive SSM session to the instance (must be running)
  help      Show this help message

Environment:
  HERMES_INSTANCE_ID   required, the instance to control
  HERMES_AWS_REGION    optional, defaults to us-east-1
EOF
}

ssm_run() {
  local cmd_id
  cmd_id=$(aws ssm send-command \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters "{\"commands\":[\"$1\"]}" \
    --query "Command.CommandId" --output text)
  sleep 10
  aws ssm get-command-invocation \
    --region "$REGION" \
    --command-id "$cmd_id" \
    --instance-id "$INSTANCE_ID" \
    --query "StandardOutputContent" --output text
}

get_state() {
  aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query "Reservations[0].Instances[0].State.Name" --output text 2>/dev/null
}

ACTION="${1:-}"
[ -z "$ACTION" ] && { usage; exit 0; }

case "$ACTION" in
  start)
    STATE=$(get_state)
    if [ "$STATE" = "running" ]; then
      echo "Instance is already running."
    else
      echo "Starting Hermes instance ($INSTANCE_ID)..."
      aws ec2 start-instances --instance-ids "$INSTANCE_ID" --region "$REGION" --output text
      echo "Waiting for instance to be running..."
      aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"
      echo "Instance is running."
    fi

    echo "Waiting for SSM to be ready..."
    sleep 15

    STATUS=$(ssm_run "systemctl is-active hermes.service")
    echo "Hermes service status: $STATUS"

    if [ "$STATUS" = "active" ]; then
      echo "Hermes is up and running."
    else
      echo "WARNING: Hermes service is '$STATUS'. Attempting restart..."
      ssm_run "systemctl restart hermes.service" > /dev/null
      echo "Restart sent. Check Hermes manually to confirm."
    fi
    ;;

  stop)
    STATE=$(get_state)
    if [ "$STATE" != "running" ]; then
      echo "Instance is not running (state: $STATE). Nothing to do."
      exit 0
    fi

    echo "Stopping Hermes service on $INSTANCE_ID..."
    ssm_run "systemctl stop hermes.service" > /dev/null || true
    echo "Hermes service stopped."

    echo "Stopping instance..."
    aws ec2 stop-instances --instance-ids "$INSTANCE_ID" --region "$REGION" --output text

    aws ec2 wait instance-stopped --instance-ids "$INSTANCE_ID" --region "$REGION"
    echo "Instance is stopped."
    ;;

  status)
    STATE=$(get_state)
    echo "Instance state: $STATE"

    if [ "$STATE" = "running" ]; then
      echo "Waiting for SSM..."
      sleep 2
      STATUS=$(ssm_run "systemctl is-active hermes.service")
      echo "Hermes service: $STATUS"

      UPTIME=$(ssm_run "systemctl show hermes.service --property=ActiveEnterTimestamp --value")
      echo "Running since: $UPTIME"
    fi
    ;;

  ssh)
    STATE=$(get_state)
    if [ "$STATE" != "running" ]; then
      echo "Instance is not running (state: $STATE). Start it first with: $(basename "$0") start"
      exit 1
    fi

    echo "Opening SSM session to $INSTANCE_ID..."
    aws ssm start-session --region "$REGION" --target "$INSTANCE_ID"
    ;;

  help|-h|--help)
    usage
    ;;

  *)
    echo "Unknown command: $ACTION" >&2
    echo "" >&2
    usage >&2
    exit 1
    ;;
esac
