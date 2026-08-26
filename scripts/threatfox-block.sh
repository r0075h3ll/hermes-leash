#!/usr/bin/env bash
# Pulls the abuse.ch ThreatFox recent feed and blocks high-confidence IPv4 IOCs
# outbound via nftables. State accumulates in /var/lib/threatfox-block.
# Kept in sync with the copy embedded in template.yaml UserData.
set -euo pipefail

FEED_URL="https://threatfox.abuse.ch/export/json/recent/"
MIN_CONF=80
STATE_FILE="/var/lib/threatfox-block/blocked.txt"
RULESET_FILE="/var/lib/threatfox-block/apply.nft"
LOG_FILE="/var/log/threatfox-block.log"

mkdir -p /var/lib/threatfox-block

log() {
  echo "$(date -Is) $*" >> "$LOG_FILE"
}

TMP=$(mktemp)
trap 'rm -f "$TMP" "$TMP.new" "$TMP.add"' EXIT

if curl -fsSL --max-time 60 "$FEED_URL" > "$TMP"; then
  jq -r '.[][] |
    select(.confidence_level >= 80 and (.ioc_type == "ip" or .ioc_type == "ip:port")) |
    .ioc_value' "$TMP" \
    | sed -E 's/^([0-9.]+):[0-9]+$/\1/' \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
    | sort -u > "$TMP.new"

  touch "$STATE_FILE"
  sort -u -o "$STATE_FILE" "$STATE_FILE"

  comm -13 "$STATE_FILE" "$TMP.new" > "$TMP.add"
  if [ -s "$TMP.add" ]; then
    cat "$TMP.add" >> "$STATE_FILE"
    sort -u -o "$STATE_FILE" "$STATE_FILE"
  fi
else
  log "WARN: feed fetch failed, reapplying last known rules"
  : > "$TMP.add"
fi

{
  echo "table ip threatfox {"
  echo "  set blocked {"
  echo "    type ipv4_addr;"
  if [ -s "$STATE_FILE" ]; then
    echo "    elements = {"
    paste -sd, "$STATE_FILE"
    echo "    }"
  fi
  echo "  }"
  echo "  chain out {"
  echo "    type filter hook output priority 0; policy accept;"
  echo "    ip daddr @blocked log prefix \"threatfox-block: \" limit rate 1/second burst 50 packets"
  echo "    ip daddr @blocked reject"
  echo "    ip daddr @blocked drop"
  echo "  }"
  echo "}"
} > "$RULESET_FILE"

nft list table ip threatfox >/dev/null 2>&1 && nft delete table ip threatfox
if nft -f "$RULESET_FILE" 2>>"$LOG_FILE"; then
  added=$(wc -l < "$TMP.add")
  total=$(wc -l < "$STATE_FILE")
  log "OK: $added new IP(s) blocked, total $total"
else
  log "ERROR: nft apply failed"
  exit 1
fi
