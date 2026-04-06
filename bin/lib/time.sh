#!/bin/bash
# Cross-platform time helpers — sourced by scripts that need time formatting.

# Convert ISO timestamp to epoch seconds (macOS + Linux compatible)
# Assumes input is UTC (Z or +00:00 suffix, or bare — treated as UTC)
_iso_to_epoch() {
  local iso="$1"
  local clean
  clean=$(echo "$iso" | sed 's/Z$//; s/+00:00$//; s/\.[0-9]*//')
  # If date-only (no T), append midnight to avoid macOS date -j filling current time
  [[ "$clean" != *T* ]] && clean="${clean}T00:00:00"
  # macOS → date -j, Linux → date -d
  TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$clean" "+%s" 2>/dev/null || \
    TZ=UTC date -d "$clean" +%s 2>/dev/null || echo "0"
}

# Convert epoch to relative time string (e.g. "3h ago", "yesterday")
# Uses calendar-day comparison for multi-day ranges (not raw delta)
_epoch_to_relative() {
  local epoch="$1"
  local now="${2:-$(date +%s)}"
  [ "$epoch" = "0" ] && echo "--" && return
  local delta=$(( now - epoch ))
  if [ "$delta" -lt 60 ]; then echo "just now"
  elif [ "$delta" -lt 3600 ]; then echo "$(( delta / 60 ))m ago"
  elif [ "$delta" -lt 86400 ]; then echo "$(( delta / 3600 ))h ago"
  else
    # Calendar-day based: compare local dates for accurate "yesterday" / "Xd ago"
    local event_date today_date
    event_date=$(date -r "$epoch" +%Y-%m-%d 2>/dev/null || \
                 date -d "@$epoch" +%Y-%m-%d 2>/dev/null || echo "")
    today_date=$(date +%Y-%m-%d)
    if [ -z "$event_date" ] || [ "$event_date" = "$today_date" ]; then echo "today"
    else
      local today_e event_e
      today_e=$(date -j -f "%Y-%m-%d" "$today_date" +%s 2>/dev/null || \
                date -d "$today_date" +%s 2>/dev/null || echo "$now")
      event_e=$(date -j -f "%Y-%m-%d" "$event_date" +%s 2>/dev/null || \
                date -d "$event_date" +%s 2>/dev/null || echo "$epoch")
      local days=$(( (today_e - event_e) / 86400 ))
      [ "$days" -lt 1 ] && days=1
      if [ "$days" -eq 1 ]; then echo "yesterday"
      else echo "${days}d ago"
      fi
    fi
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
