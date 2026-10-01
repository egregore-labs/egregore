#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$REPO_ROOT/tmp"
ROOT="$(mktemp -d "$REPO_ROOT/tmp/greeting-pending-turns.XXXXXX")"
GREET_ROOT="$ROOT/memory"
PROJECT_ROOT="$ROOT/project"
GREETING_RUN_ID="greeting-pending-turns-test-$$"
cleanup() {
  wait 2>/dev/null || true
  rm -f "/tmp/egregore-subagent-ctx-${GREETING_RUN_ID}.txt"
  rm -rf "$ROOT"
}
trap cleanup EXIT

# The subject is the real renderer, with local config/state and no startup or
# package-install side effects from the developer's launching environment.
while IFS='=' read -r fixture_name _; do
  case "$fixture_name" in EGREGORE_*|QMD_*) unset "$fixture_name" ;; esac
done < <(env)
export HOME="$ROOT/home" TMPDIR="$ROOT/tmp"
export XDG_CACHE_HOME="$HOME/.cache" XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share"
export EGREGORE_NO_TELEMETRY=1
mkdir -p "$HOME" "$TMPDIR" "$ROOT/fake-bin" "$PROJECT_ROOT/bin/lib"
for fixture_script in greeting metrics notices health-footer; do
  cp "$REPO_ROOT/bin/lib/$fixture_script.sh" "$PROJECT_ROOT/bin/lib/"
done
printf '{"mode":"local","org_name":"Pending turns fixture","repo_name":"egregore"}\n' > "$PROJECT_ROOT/egregore.json"
for fixture_script in telemetry startup-check; do
  printf '#!/bin/sh\nexit 0\n' > "$PROJECT_ROOT/bin/$fixture_script.sh"
done
for fixture_command in npx npm qmd gh curl wget; do
  printf '#!/bin/sh\nexit 1\n' > "$ROOT/fake-bin/$fixture_command"
  chmod +x "$ROOT/fake-bin/$fixture_command"
done
export PATH="$ROOT/fake-bin:$PATH"

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
  SCRIPT_DIR="$PROJECT_ROOT" \
  EGREGORE_MEMORY_ROOT="${EGREGORE_MEMORY_ROOT:-$GREET_ROOT}" \
  STATE_FILE="$ROOT/state.json" \
  CTX_DIR="$ROOT/context" \
  CONFIG="$PROJECT_ROOT/egregore.json" \
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
  EGREGORE_SESSION_ID="$GREETING_RUN_ID" \
  FIRST_SESSION="" \
  DISPLAY_NAME_STATE="" \
  DASHBOARD_URL="" \
  BOARD_URL="" \
  LOOM_DOCTOR_BRIEF="" \
  EGREGORE_NOTICE_LEDGER=off \
  "${1:-bash}" "$PROJECT_ROOT/bin/lib/greeting.sh"
}

EMPTY_ROOT="$ROOT/empty-memory"
EMPTY_EVENTS_ROOT="$ROOT/empty-events-memory"
NO_CREATOR_ROOT="$ROOT/no-creator-memory"
mkdir -p "$EMPTY_ROOT" "$EMPTY_EVENTS_ROOT/scrolls/.events" "$EMPTY_EVENTS_ROOT/harvests/.events" "$NO_CREATOR_ROOT/scrolls/.events"
printf '%s\n' 'a turn without creator' > "$NO_CREATOR_ROOT/scrolls/no-creator.md"
printf '%s\n' '{"type":"turn-received","id":"no-owner"}' > "$NO_CREATOR_ROOT/scrolls/.events/no-creator.jsonl"

for greeting_shell in bash zsh; do
  if ! command -v "$greeting_shell" >/dev/null 2>&1; then
    echo "SKIP: $greeting_shell unavailable for pending-turn greeting checks"
    continue
  fi
  greeting_output="$(run_greeting "$greeting_shell")"
  pending_line="$(printf '%s\n' "$greeting_output" | grep -F '  ⧖ ' || true)"
  expected_line='  ⧖ 3 pending turn(s) on your scrolls: owned-scroll (2), surface (1)'
  [ "$pending_line" = "$expected_line" ] || {
    echo "unexpected pending-turn line ($greeting_shell): $pending_line" >&2
    exit 1
  }

  # Missing directories, empty directories and records without creators must
  # all finish rendering, with no pending-turn notification.
  for quiet_memory in "$EMPTY_ROOT" "$EMPTY_EVENTS_ROOT" "$NO_CREATOR_ROOT"; do
    quiet_output="$(EGREGORE_MEMORY_ROOT="$quiet_memory" run_greeting "$greeting_shell")"
    if grep -Fq 'pending turn(s) on your scrolls' <<< "$quiet_output"; then
      echo "unexpected pending-turn notification ($greeting_shell): $quiet_memory" >&2
      exit 1
    fi
    grep -Fq 'Display the above greeting' <<< "$quiet_output" || {
      echo "incomplete greeting ($greeting_shell): $quiet_memory" >&2
      exit 1
    }
  done
  echo "ok — pending-turn greeting projection passes ($greeting_shell)"
done
