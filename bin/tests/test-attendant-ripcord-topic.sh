#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMPD="$(mktemp -d -t eg-attendant-topic-XXXXXX)"
trap 'rm -rf "$TMPD"' EXIT

awk '/^# --- Commands/{exit} {print}' "$ROOT/bin/attendant.sh" > "$TMPD/attendant-lib.sh"
# shellcheck source=/dev/null
source "$TMPD/attendant-lib.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local got="$1"
  local want="$2"
  local label="$3"

  [ "$got" = "$want" ] || fail "$label: got '$got', want '$want'"
  echo "PASS: $label"
}

prompts=$(cat <<'EOF'
start
there was a handoff from cem with harvest to make decisions on emissary product find that and give me the link
yes - it also had egregore.xyz link cant u find it?
[Request interrupted by user]
EOF
)

gitsum=$(cat <<'EOF'
- `develop` — 1 uncommitted, 0 unpushed (curve-labs-core)
- `dev/oguzhan/bump-create-egregore-0-17-0` — 0 uncommitted, 1 unpushed (create-egregore-in-repo-detection)
- `bugfix/fix-alpha-invite-command-leak` — 0 uncommitted, 4 unpushed (fix-alpha-invite-command-leak)
EOF
)

assert_eq "$(_ripcord_topic_slug "$prompts" "$gitsum" "oguzhan")" \
  "there-was-a-handoff-from-cem-with-harvest-to-make-decisions-on-emissary" \
  "prompt-derived topic beats dirty branch fallback"

assert_eq "$(_ripcord_topic_slug "start" "$gitsum" "oguzhan")" \
  "bump-create-egregore-0-17-0" \
  "branch fallback scans past develop"

assert_eq "$(_ripcord_topic_slug "" "- \`develop\` — 1 uncommitted, 0 unpushed (repo)" "oguzhan")" \
  "session" \
  "generic fallback remains session"
