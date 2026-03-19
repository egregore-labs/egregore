#!/bin/bash
set -euo pipefail

# Pulse Weekly Report — sends the full week's runs to Sonnet for deep synthesis,
# then delivers the narrative assessment via Telegram.
#
# Usage: bash bin/pulse-report.sh [days=7] [recipient=cemfd]

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$SCRIPT_DIR/egregore.json"
NOTIFY="$SCRIPT_DIR/bin/notify.sh"
TELEMETRY="$SCRIPT_DIR/bin/telemetry.sh"
PULSE_LOG="$SCRIPT_DIR/.pulse/runs.jsonl"
DAYS="${1:-7}"
# Recipient: arg > config > default (cem for testing)
RECIPIENT="${2:-$(jq -r '.pulse.report_recipient // "cem"' "$CONFIG" 2>/dev/null || echo "cem")}"

if [ ! -f "$PULSE_LOG" ] || [ ! -s "$PULSE_LOG" ]; then
  echo "No pulse data yet."
  exit 0
fi

# --- Config ---
ENV_FILE="$SCRIPT_DIR/.env"
API_URL=$(jq -r '.api_url // empty' "$CONFIG" 2>/dev/null)
API_KEY=""
if [ -f "$ENV_FILE" ]; then
  API_KEY=$(grep '^EGREGORE_API_KEY=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- || true)
  _url=$(grep '^EGREGORE_API_URL=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- || true)
  [ -n "$_url" ] && API_URL="$_url"
fi

if [ -z "$API_URL" ] || [ -z "$API_KEY" ]; then
  echo "Error: API config required." >&2
  exit 1
fi

# --- Filter to last N days ---
CUTOFF=$(python3 -c "from datetime import datetime, timedelta; print((datetime.utcnow() - timedelta(days=$DAYS)).strftime('%Y-%m-%dT%H:%M:%SZ'))" 2>/dev/null)

RUNS=$(jq -c "select(.timestamp >= \"$CUTOFF\")" "$PULSE_LOG" 2>/dev/null | jq -s '.' 2>/dev/null)
TOTAL=$(echo "$RUNS" | jq 'length' 2>/dev/null || echo "0")

if [ "$TOTAL" -eq 0 ]; then
  bash "$NOTIFY" send "$RECIPIENT" "Pulse report (${DAYS}d): No runs recorded yet." 2>/dev/null
  exit 0
fi

# --- Call Sonnet for deep synthesis ---
PAYLOAD=$(jq -n -c --argjson runs "$RUNS" --argjson days "$DAYS" \
  '{runs: $runs, period_days: $days}')

RESPONSE=$(curl -sf -X POST "${API_URL}/api/spirits/pulse-report" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  --max-time 90 2>/dev/null || echo '{"report":""}')

REPORT=$(echo "$RESPONSE" | jq -r '.report // empty' 2>/dev/null)

if [ -z "$REPORT" ]; then
  # Fallback: send basic stats if synthesis fails
  STATS=$(echo "$RUNS" | jq '{
    sessions: length,
    edges: [.[].response.edges[]?] | length,
    signals: [.[].response.signals[]?] | length
  }')
  bash "$NOTIFY" send "$RECIPIENT" "Pulse report (${DAYS}d): ${TOTAL} sessions pulsed, synthesis unavailable. Stats: $STATS" 2>/dev/null
  exit 0
fi

# --- Send via Telegram ---
bash "$NOTIFY" send "$RECIPIENT" "$REPORT" 2>/dev/null
echo "$REPORT"

# --- Save locally ---
REPORT_DIR="$SCRIPT_DIR/.pulse/reports"
mkdir -p "$REPORT_DIR" 2>/dev/null
REPORT_FILE="$REPORT_DIR/$(date -u +%Y-%m-%d).md"
echo "$REPORT" > "$REPORT_FILE" 2>/dev/null

# Also save the raw JSON for analysis
echo "$RESPONSE" | jq --arg period "${DAYS}d" --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson run_count "$TOTAL" \
  '. + {period: $period, generated: $generated, run_count: $run_count}' \
  > "${REPORT_FILE%.md}.json" 2>/dev/null

# --- Telemetry ---
bash "$TELEMETRY" emit "pulse_report" \
  "$(jq -n -c --argjson runs "$TOTAL" --argjson days "$DAYS" '{runs: $runs, period_days: $days}')" 2>/dev/null &

echo "Report saved to $REPORT_FILE"
