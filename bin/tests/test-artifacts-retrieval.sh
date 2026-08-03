#!/bin/bash
# Smoke test — artifact finder: OSS/grep vs paid/graph gating + fallback.
#
# Read-only (no graph writes) and safe to re-run. It asserts WHICH retrieval
# path fires for each mode, that each returns results, and that graph hits carry
# the url + relationship annotations grep can't produce. Uses the EGREGORE_MODE
# / EGREGORE_API_URL override hooks so it never touches your committed config.
#
#   bash bin/tests/test-artifacts-retrieval.sh

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
A="$ROOT/bin/artifacts.sh"
Q="egregore"
fails=0
ok() { printf '  \033[0;32m✓\033[0m %s\n' "$1"; }
no() { printf '  \033[0;31m✗\033[0m %s\n' "$1"; fails=$((fails + 1)); }
has() { printf '%s' "$1" | grep -q -- "$2"; }

MODE="$(jq -r '.mode // "connected"' "$ROOT/egregore.json" 2>/dev/null)"
echo "egregore.json mode: $MODE"
echo

echo "1) default mode → correct path + results"
OUT="$(bash "$A" find "$Q" 2>&1)"
if [ "$MODE" = "local" ]; then
  has "$OUT" 'grep-rank' && ok "local → grep path" || no "local: expected grep path"
else
  has "$OUT" ' graph ' && ok "connected → graph path" || no "connected: expected graph path"
fi
has "$OUT" '●' && ok "returns results" || no "no results"
echo

echo "2) EGREGORE_MODE=local (OSS simulation) → grep, never the graph"
OUT="$(EGREGORE_MODE=local bash "$A" find "$Q" 2>&1)"
has "$OUT" 'grep-rank' && ok "forces grep path" || no "expected grep path"
has "$OUT" '●' && ok "returns results" || no "no results"
echo

echo "3) connected + broken graph → falls back to grep"
OUT="$(EGREGORE_MODE=connected EGREGORE_API_URL='https://invalid.invalid.invalid' bash "$A" find "$Q" 2>&1)"
has "$OUT" 'grep-rank' && ok "graph offline → grep fallback" || no "expected grep fallback"
echo

if [ "$MODE" != "local" ]; then
  # Relationship annotation (· by author / quest) is the graph's unique value —
  # grep can't traverse edges. Assert it appears in normal graph output.
  echo "4) graph hit carries the relationship annotation grep can't"
  OUT="$(bash "$A" find "pricing" 2>&1)"
  has "$OUT" ' · by ' && ok "surfaces author relationship" || no "no author annotation"
  # And that hosted artifacts surface their url (data-derived so it's not tied to
  # one record): pull any url-bearing artifact and search a distinctive title word.
  SAMPLE="$(bash "$ROOT/bin/graph.sh" query 'MATCH (a:Artifact) WHERE a.url IS NOT NULL AND a.url <> "" RETURN a.title LIMIT 1' 2>/dev/null | jq -r '.values[0][0] // ""')"
  if [ -n "$SAMPLE" ]; then
    WORD="$(printf '%s' "$SAMPLE" | tr -c 'a-zA-Z' ' ' | tr ' ' '\n' | awk '{ if (length > m) { m = length; w = $0 } } END { print tolower(w) }')"
    OUT="$(bash "$A" find "$WORD" 2>&1)"
    has "$OUT" 'egregore.xyz' && ok "surfaces url (via '$WORD')" || no "no url for '$WORD'"
  else
    echo "  (skip url check — no url-bearing artifact in graph)"
  fi
  echo
fi

echo "5) temporal parsing + flags"
OUT="$(bash "$A" find "egregore yesterday" 2>&1)"
has "$OUT" ' · on ' && ok "relative 'yesterday' → date window" || no "yesterday not parsed"
OUT="$(bash "$A" find --on 2026-01-01 egregore 2>&1)"
has "$OUT" ' · on 2026-01-01' && ok "--on flag → explicit window" || no "--on not honored"
echo

if [ "$fails" -eq 0 ]; then
  echo "SMOKE: ALL PASS"
  exit 0
else
  echo "SMOKE: $fails FAILED"
  exit 1
fi
