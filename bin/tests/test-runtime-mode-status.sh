#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cp "$ROOT/bin/statusline.sh" "$TMP/statusline.sh"
mkdir -p "$TMP/bin/lib"
cp "$ROOT/bin/lib/config.sh" "$TMP/bin/lib/config.sh"

git -C "$TMP" init -q
git -C "$TMP" config user.email "runtime-status@example.com"
git -C "$TMP" config user.name "Runtime Status"
printf 'fixture\n' > "$TMP/tracked.txt"
git -C "$TMP" add tracked.txt
git -C "$TMP" commit -qm "fixture"

printf '{"mode":"local"}\n' > "$TMP/egregore.json"
local_status="$(cd "$TMP" && bash statusline.sh)"
grep -q '^◇ LOCAL · ⎇ ' <<< "$local_status"
! grep -q 'CONNECTED' <<< "$local_status"

printf '{"mode":"connected"}\n' > "$TMP/egregore.json"
incomplete_status="$(cd "$TMP" && bash statusline.sh)"
grep -q '^◇ LOCAL · ⎇ ' <<< "$incomplete_status"

printf '{"mode":"connected","api_url":"https://api.egregore.example"}\n' > "$TMP/egregore.json"
connected_status="$(cd "$TMP" && bash statusline.sh)"
grep -q '^◆ CONNECTED · ⎇ ' <<< "$connected_status"

printf 'changed\n' >> "$TMP/tracked.txt"
dirty_status="$(cd "$TMP" && bash statusline.sh)"
grep -q '· 1 unsaved$' <<< "$dirty_status"

echo "runtime mode status ok"
