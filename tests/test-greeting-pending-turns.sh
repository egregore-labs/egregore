#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$REPO_ROOT/tmp"
ROOT="$(mktemp -d "$REPO_ROOT/tmp/greeting-pending-turns.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
GREET_ROOT="$ROOT/memory"

bash -n "$REPO_ROOT/bin/lib/greeting.sh"
bash -n "$REPO_ROOT/bin/session-start.sh"

mkdir -p "$GREET_ROOT/scrolls/.events" "$GREET_ROOT/harvests/.events" "$ROOT/context"
node - "$GREET_ROOT" <<'NODE'
import fs from 'node:fs';
import path from 'node:path';

const root = process.argv[2];
const received = (id, answers = [{ fork: 'F1', pick: 'A', note: 'note' }]) => ({
  type: 'turn-received',
  id,
  answers
});
const review = (id, disposition, note) => ({
  id: `review|${id}`,
  type: 'turn-reviewed',
  turn: id,
  disposition,
  by: 'cem',
  date: '2026-07-16',
  ...(note === undefined ? {} : { note })
});

fs.writeFileSync(path.join(root, 'scrolls', 'owned-scroll.md'), '---\ncreator: cem\n---\n');
fs.writeFileSync(path.join(root, 'scrolls', 'other-scroll.md'), '---\ncreator: other\n---\n');
const owned = [
  received('s-unreviewed'),
  received('s-open-accepted', []),
  review('s-open-accepted', 'accepted'),
  received('s-declined'),
  review('s-declined', 'declined', 'No.'),
  received('s-absorbed'),
  { id: 'v2', type: 'version-published', v: 2, absorbs: ['s-absorbed'] }
];
fs.writeFileSync(
  path.join(root, 'scrolls', '.events', 'owned-scroll.jsonl'),
  `${owned.map(JSON.stringify).join('\n')}\n`
);
fs.writeFileSync(
  path.join(root, 'scrolls', '.events', 'other-scroll.jsonl'),
  `${JSON.stringify(received('other-unreviewed'))}\n`
);
fs.writeFileSync(path.join(root, 'scrolls', 'broken.md'), '---\ncreator: cem\n---\n');
fs.writeFileSync(path.join(root, 'scrolls', '.events', 'broken.jsonl'), '{"type":"turn-received"\n');
fs.writeFileSync(
  path.join(root, 'scrolls', '.events', 'evil;printf-pwned.jsonl'),
  `${JSON.stringify(received('hostile'))}\n`
);
fs.writeFileSync(
  path.join(root, 'harvests', 'surface.json'),
  JSON.stringify({ source: 'source.md', author: 'cem', trusted: [] })
);
const surface = [
  received('h-unreviewed'),
  received('h-applied'),
  {
    id: 'applied|h-applied',
    type: 'turn-applied',
    turn: 'h-applied',
    date: '2026-07-16',
    targets: ['source.md']
  }
];
fs.writeFileSync(
  path.join(root, 'harvests', '.events', 'surface.jsonl'),
  `${surface.map(JSON.stringify).join('\n')}\n`
);
NODE

printf '%s\n' '{"alias_version":2,"github_username":"other"}' > "$ROOT/state.json"

run_greeting() {
  SCRIPT_DIR="$REPO_ROOT" \
  EGREGORE_MEMORY_ROOT="${EGREGORE_MEMORY_ROOT:-$GREET_ROOT}" \
  STATE_FILE="$ROOT/state.json" \
  CTX_DIR="$ROOT/context" \
  CONFIG="$REPO_ROOT/egregore.json" \
  BRANCH="greeting-pending-turns-test" \
  COMMITS_AHEAD=0 \
  AUTHOR="other" \
  EGREGORE_PERSON="cem" \
  LOCAL_MODE=true \
  MEMORY_SYNCED=true \
  REPOS_STATUS="" \
  SAVED_BRANCH="" \
  HEALTH_GITHUB=ok \
  HEALTH_GIT=ok \
  HEALTH_APIKEY=skip \
  HEALTH_GRAPH=skip \
  HEALTH_TELEGRAM=skip \
  FRAMEWORK_VERSION=6 \
  TIME_OF_DAY=day \
  EGREGORE_SESSION_ID=greeting-pending-turns-test \
  FIRST_SESSION="" \
  DISPLAY_NAME_STATE="" \
  DASHBOARD_URL="" \
  BOARD_URL="" \
  LOOM_DOCTOR_BRIEF="" \
  bash "$REPO_ROOT/bin/lib/greeting.sh"
}

greeting_output="$(run_greeting)"
pending_line="$(printf '%s\n' "$greeting_output" | grep -F '  ⧖ ' || true)"
expected_line='  ⧖ 3 pending turn(s) on your scrolls: owned-scroll (2), surface (1)'
[ "$pending_line" = "$expected_line" ] || {
  echo "unexpected pending-turn line: $pending_line" >&2
  exit 1
}

EMPTY_ROOT="$ROOT/empty-memory"
mkdir -p "$EMPTY_ROOT"
empty_output="$(EGREGORE_MEMORY_ROOT="$EMPTY_ROOT" run_greeting)"
if printf '%s\n' "$empty_output" | grep -Fq 'pending turn(s) on your scrolls'; then
  echo "greeting was not silent for missing event directories" >&2
  exit 1
fi

NO_CREATOR_ROOT="$ROOT/no-creator-memory"
mkdir -p "$NO_CREATOR_ROOT/scrolls/.events"
printf '%s\n' 'a turn without creator' > "$NO_CREATOR_ROOT/scrolls/no-creator.md"
printf '%s\n' '{"type":"turn-received","id":"no-owner"}' > "$NO_CREATOR_ROOT/scrolls/.events/no-creator.jsonl"
no_creator_output="$(EGREGORE_MEMORY_ROOT="$NO_CREATOR_ROOT" run_greeting)"
if printf '%s\n' "$no_creator_output" | grep -Fq 'pending turn(s) on your scrolls'; then
  echo "greeting counted a record without creator" >&2
  exit 1
fi

echo "ok — pending-turn greeting projection passes independently of the scroll suite"
