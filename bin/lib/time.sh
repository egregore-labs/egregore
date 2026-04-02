#!/bin/bash
# Cross-platform time helpers — sourced by scripts that need time formatting.

# Convert ISO timestamp to epoch seconds (macOS + Linux compatible)
_iso_to_epoch() {
  local iso="$1"
  local clean
  clean=$(echo "$iso" | sed 's/Z$//; s/+00:00$//; s/\.[0-9]*//')
  # If date-only (no T), append midnight to avoid macOS date -j filling current time
  [[ "$clean" != *T* ]] && clean="${clean}T00:00:00"
  if command -v gdate &>/dev/null; then
    gdate -d "$clean" +%s 2>/dev/null || echo "0"
  else
    date -j -f "%Y-%m-%dT%H:%M:%S" "$clean" "+%s" 2>/dev/null || echo "0"
  fi
}

# Convert epoch to relative time string (e.g. "3h ago", "yesterday")
_epoch_to_relative() {
  local epoch="$1"
  local now="${2:-$(date +%s)}"
  [ "$epoch" = "0" ] && echo "--" && return
  local delta=$(( now - epoch ))
  if [ "$delta" -lt 60 ]; then echo "just now"
  elif [ "$delta" -lt 3600 ]; then echo "$(( delta / 60 ))m ago"
  elif [ "$delta" -lt 86400 ]; then echo "$(( delta / 3600 ))h ago"
  elif [ "$delta" -lt 172800 ]; then echo "yesterday"
  else echo "$(( delta / 86400 ))d ago"
  fi
}

# Millisecond timer (for latency measurement)
_millis() {
  if command -v gdate &>/dev/null; then
    gdate +%s%3N
  else
    python3 -c "import time; print(int(time.time() * 1000))" 2>/dev/null || echo "0"
  fi
}
