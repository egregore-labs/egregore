#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/bin/lib/handoff-meta.sh"

TMPD="$(mktemp -d -t eg-handoff-meta-XXXXXX)"
trap 'rm -rf "$TMPD"' EXIT

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

mkdir -p "$TMPD/handoffs/2026-07"

cat > "$TMPD/handoffs/2026-07/06-oguzhan-ripcord-session.md" <<'EOF'
---
date: 2026-07-06
author: oguzhan
to: oguzhan
kind: ripcord
status: draft
topic: session
---

# Ripcord: session

Automatic capture.
EOF

cat > "$TMPD/handoffs/2026-07/05-cem-manual-handoff.md" <<'EOF'
# Handoff: Manual sender

**Date**: 2026-07-05
**Author**: Cem -> Oz

Body.
EOF

cat > "$TMPD/handoffs/2026-07/04-renckorzay-ripcord-session.md" <<'EOF'
# Ripcord: session

No explicit author.
EOF

assert_eq "$(eg_handoff_author "$TMPD/handoffs/2026-07/06-oguzhan-ripcord-session.md")" "oguzhan" "yaml author"
assert_eq "$(eg_handoff_topic "$TMPD/handoffs/2026-07/06-oguzhan-ripcord-session.md")" "Ripcord: session" "h1 topic"
assert_eq "$(eg_handoff_date "$TMPD/handoffs/2026-07/06-oguzhan-ripcord-session.md")" "2026-07-06" "yaml date"

assert_eq "$(eg_handoff_author "$TMPD/handoffs/2026-07/05-cem-manual-handoff.md")" "Cem -> Oz" "legacy author"
assert_eq "$(eg_handoff_topic "$TMPD/handoffs/2026-07/05-cem-manual-handoff.md")" "Manual sender" "legacy topic"
assert_eq "$(eg_handoff_date "$TMPD/handoffs/2026-07/05-cem-manual-handoff.md")" "2026-07-05" "legacy date"

assert_eq "$(eg_handoff_author "$TMPD/handoffs/2026-07/04-renckorzay-ripcord-session.md")" "renckorzay" "filename author fallback"
assert_eq "$(eg_handoff_date "$TMPD/handoffs/2026-07/04-renckorzay-ripcord-session.md")" "2026-07-04" "filename date fallback"
