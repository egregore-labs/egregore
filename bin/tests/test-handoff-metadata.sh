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

# --- bin/lib/handoff_meta.py: the startup gather's one-pass reader ---------
# It must give what these shell functions give, field for field, including
# xargs' quote and whitespace handling, and the gather's Repo State rows.

cat > "$TMPD/handoffs/2026-07/03-ada-quoted.md" <<'EOF'
intro
---
not: here
---
# Handoff:   "Quoted"  topic  'here'
**From**: Ada "A" Byron   →   Bob

## Repo State

| Repo | Branch | PR | Base |
|------|--------|----|------|
| egregore | dev/ada/x | #123 | develop |
| site | main | — | main |
| api | feat/y | #007 | develop |
|  | no-repo | 1 | main |
| short | only |
## Next
| after | heading | 2 | main |
EOF

cat > "$TMPD/handoffs/2026-07/02-bo-yaml.md" <<'EOF'
# -n flagged topic
body
---
author: 'bo "b" lee'
date: "2026-07-02"
---
EOF
printf '# CRLF topic\r\n**Author**: cy\r\n**Date**: 2026-07-01\r\n' > "$TMPD/handoffs/2026-07/01-cy-crlf.md"
printf '# Broken\n**Author**: it'"'"'s\n## Repo State\n| it'"'"'s | b | 2 | x |\n| ok | b | 3 | y |\n' \
  > "$TMPD/handoffs/2026-07/00-di-quote.md"

FILES=("$TMPD"/handoffs/2026-07/*.md)
python3 "$ROOT/bin/lib/handoff_meta.py" addressed "$TMPD/names" "$TMPD/rich" "${FILES[@]}" \
  || fail "handoff_meta.py exited non-zero"

index=0
for file in "${FILES[@]}"; do
  name="$(basename "$file" .md)"
  assert_eq "$(jq -r ".[$index]" "$TMPD/names")" "$name" "one-pass name: $name"
  assert_eq "$(jq -r ".[$index].author" "$TMPD/rich")" "$(eg_handoff_author "$file")" "one-pass author: $name"
  assert_eq "$(jq -r ".[$index].topic" "$TMPD/rich")" "$(eg_handoff_topic "$file")" "one-pass topic: $name"
  assert_eq "$(jq -r ".[$index].date" "$TMPD/rich")" "$(eg_handoff_date "$file")" "one-pass date: $name"
  index=$((index + 1))
done

assert_eq "$(head -c 40 "$TMPD/names")" '["00-di-quote","01-cy-crlf","02-bo-yaml"' "names file shape"
assert_eq "$(jq -c '.[] | select(.name == "03-ada-quoted") | .repoState' "$TMPD/rich")" \
  '[{"repo":"egregore","branch":"dev/ada/x","pr":123,"base":"develop"},{"repo":"site","branch":"main","pr":null,"base":"main"},{"repo":"api","branch":"feat/y","pr":7,"base":"develop"},{"repo":"short","branch":"only","pr":null,"base":""}]' \
  "repo state rows"
assert_eq "$(jq -c '.[] | select(.name == "00-di-quote") | .repoState' "$TMPD/rich")" \
  '[{"repo":"ok","branch":"b","pr":3,"base":"y"}]' "an unparseable cell drops its row"
assert_eq "$(jq -c '.[] | select(.name == "01-cy-crlf")' "$TMPD/rich")" \
  '{"name":"01-cy-crlf","author":"cy\r","topic":"CRLF topic\r","date":"2026-07-01\r","repoState":[]}' \
  "compact entry, carriage returns kept as the pipeline kept them"

# One handoff the parser cannot read keeps its place in both lists with
# empty details; the others are unaffected.
printf '# boom\n\n**Topic**: boom\n' > "$TMPD/boom.md"
CONTAINED=$(PYTHONSAFEPATH=1 PYTHONPATH="$ROOT/bin/lib" python3 -c '
import sys, handoff_meta
real = handoff_meta.topic
def topic(lines):
    if any("boom" in line for line in lines):
        raise RuntimeError("unparseable")
    return real(lines)
handoff_meta.topic = topic
names, rich = handoff_meta.addressed(sys.argv[1:])
print(names)
print(rich)
' "$TMPD/boom.md" "${FILES[0]}" 2>/dev/null) || true
assert_eq "$(printf '%s\n' "$CONTAINED" | sed -n 2p | jq -c '.[0]')" \
  '{"name":"boom","author":"","topic":"","date":"","repoState":[]}' \
  "a handoff the parser cannot read keeps its name, not the list"
assert_eq "$(printf '%s\n' "$CONTAINED" | sed -n 2p | jq 'length')" "2" \
  "the other handoffs are still listed"
