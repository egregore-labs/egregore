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
echo "$local_status" | grep -q '^◇ LOCAL · ⎇ '
! echo "$local_status" | grep -q 'CONNECTED'

printf '{"mode":"connected"}\n' > "$TMP/egregore.json"
incomplete_status="$(cd "$TMP" && bash statusline.sh)"
echo "$incomplete_status" | grep -q '^◇ LOCAL · ⎇ '

printf '{"mode":"connected","api_url":"https://api.egregore.example"}\n' > "$TMP/egregore.json"
connected_status="$(cd "$TMP" && bash statusline.sh)"
echo "$connected_status" | grep -q '^◆ CONNECTED · ⎇ '

printf 'changed\n' >> "$TMP/tracked.txt"
dirty_status="$(cd "$TMP" && bash statusline.sh)"
echo "$dirty_status" | grep -q '· 1 unsaved$'

echo "runtime mode status ok"
