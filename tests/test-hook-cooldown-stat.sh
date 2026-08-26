#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

stat() {
  case "${1:-}" in
    -c)
      echo 1000000000
      ;;
    -f)
      echo "  File: ${3:-unknown}"
      echo "    ID: deadbeef Namelen: 255 Type: ext2/ext3"
      ;;
    *)
      return 1
      ;;
  esac
}
export -f stat

project_hash=$( { md5sum <<<"$ROOT" 2>/dev/null || md5 -q -s "$ROOT" 2>/dev/null || echo default; } | cut -c1-8 )
dir_hash=$( { md5sum <<<"$ROOT" 2>/dev/null || md5 -q -s "$ROOT" 2>/dev/null || echo default; } | cut -c1-8 )
save_stamp="/tmp/.egregore-save-reminder-${project_hash}"
autosave_stamp="/tmp/.egregore-autosave-${dir_hash}"

touch "$save_stamp" "$autosave_stamp"

# GNU stat accepts `-f %m` but prints a filesystem report whose first word is
# "File". With `set -u`, treating that output as arithmetic raises the exact
# stop-hook error this regression protects against.
bash "$ROOT/bin/save-reminder.sh" >/dev/null
bash "$ROOT/bin/session-autosave.sh" \
  --dir "$ROOT" --debounce 600 >/dev/null

echo "hook cooldown stat portability: ok"
