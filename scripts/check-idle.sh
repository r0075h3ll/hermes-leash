#!/usr/bin/env bash
# Stops the instance when nobody has talked to Hermes for a while.
#
# The CloudFormation template installs this with a systemd timer that fires
# every 60 seconds. This standalone copy is handy if you run Hermes some other
# way — set the env vars below and wire it into cron or a timer yourself.
#
# Activity is measured by grepping the gateway log for "inbound message".
# Internal state files change constantly even when nothing is happening,
# so file mtimes are useless here.
set -euo pipefail

IDLE_MINUTES="${IDLE_MINUTES:-10}"
HERMES_LOG="${HERMES_LOG:-/home/hermes/.hermes/logs/gateway.log}"
LOG_FILE="${IDLE_LOG:-/home/hermes/idle-monitor.log}"
OVERRIDE="${IDLE_OVERRIDE:-/home/hermes/.idle-shutdown-disabled}"   # touch this file to disable the monitor
SNS_TOPIC="${SNS_TOPIC:-}"                                          # optional: topic ARN to notify before shutdown
NOTIFY_REGION="${AWS_REGION:-us-east-1}"

log() { echo "[$(date -u)] $*" >> "$LOG_FILE"; }

log "Running idle check"

if [ -f "$OVERRIDE" ]; then
  log "Override file exists. Skipping."
  exit 0
fi

if [ ! -f "$HERMES_LOG" ]; then
  log "No gateway log yet. Staying up."
  exit 0
fi

LAST_MSG=$(grep "inbound message" "$HERMES_LOG" 2>/dev/null | tail -1 | cut -d' ' -f1-2 | sed 's/,.*//')

if [ -z "$LAST_MSG" ]; then
  log "No inbound messages ever received. Staying up for safety."
  exit 0
fi

LAST_EPOCH=$(date -d "$LAST_MSG" +%s 2>/dev/null || echo 0)
NOW_EPOCH=$(date +%s)
DIFF=$(( (NOW_EPOCH - LAST_EPOCH) / 60 ))

if [ "$DIFF" -ge "$IDLE_MINUTES" ]; then
  INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id || echo unknown)
  log "No Telegram messages for ${DIFF}m (last at $LAST_MSG). Shutting down."

  if [ -n "$SNS_TOPIC" ]; then
    aws sns publish \
      --region "$NOTIFY_REGION" \
      --topic-arn "$SNS_TOPIC" \
      --subject "Hermes Agent - Auto-Shutdown" \
      --message "Hermes idle for ${DIFF}m (last message at $LAST_MSG). Instance ${INSTANCE_ID} stopped at $(date -u)." \
      >> "$LOG_FILE" 2>&1 || true
  fi

  /usr/sbin/shutdown -h now
else
  log "Last message ${DIFF}m ago. Staying up."
fi
