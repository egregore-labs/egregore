Pull latest for current repo and shared memory.

**Note:** `/activity` auto-syncs. Use `/pull` only when you need to sync without viewing activity.

## Loom routing

**Skip this section if your prompt contains `LOOM-EXECUTOR`** — you are the executor; run the skill as specced below. Full protocol: `.claude/context/loom.md`.

1. Resolve: `ROUTE=$(bash bin/loom.sh route pull)`, then `DECISION_ID=$(printf '%s\n' "$ROUTE" | jq -r '.decision_id // empty')`.
2. If `mode` ≠ `delegate`, or the user signalled depth ("deep", "think hard", `--deep`) → run this skill inline as normal. On a depth override, print `bash bin/loom.sh footer pull --override` after the output and set `"override":true` in telemetry.
3. Otherwise delegate: spawn the Agent tool with `subagent_type:
   "loom-executor"`, `model` = the route's `tier`, prompt =
   `LOOM-DECISION-ID: $DECISION_ID` on its own first line, then
   `LOOM-EXECUTOR: Execute .claude/skills/pull/SKILL.md`, plus the user's
   arguments and any context the spec needs from the session. Print the
   executor's final output **verbatim**, then print the output of
   `bash bin/loom.sh footer pull`.
4. If the spawn fails or the executor's first line is `LOW_CONFIDENCE:` —
   triage the reason: needs-user-interaction or a main-loop-only tool → take
   over and finish this skill inline (no escalation); genuine uncertainty or
   failure → reassign `ROUTE=$(bash bin/loom.sh escalate pull "<reason>")`,
   refresh `DECISION_ID` from `ROUTE`, then re-spawn once on the new tier
   carrying the returned decision ID
   (sticky for this session).
5. Telemetry (fire-and-forget):
   `bash bin/telemetry.sh emit "command" '{"command":"pull","routed":true,"mode":"delegate","model":"<actual>","route_tier":"<table tier>","class":"<class>","escalated":<bool>,"override":<bool>,"source":"<source>"}' 2>/dev/null &`

## What to do

1. Resolve the validated base branch with `bin/lib/config.sh` → `_get_base_branch`, then sync it with remote
2. If on a `dev/*` working branch, rebase onto the base branch (fallback: merge)
3. Check memory symlink exists — if not, derive directory from `egregore.json` and create symlink
4. Pull memory repo via symlink

## Execution

```bash
# 1. Update local base branch ref without switching branches (safe for concurrent sessions)
# Pass a managed repo name to _get_base_branch when operating on one.
BASE_BRANCH=$(bash -c 'SCRIPT_DIR="$PWD"; CONFIG="$PWD/egregore.json"; . "$PWD/bin/lib/config.sh" && _get_base_branch "$1"' _ "${REPO:-}") ||
  { echo "Could not resolve the configured base branch; stopping before Git changes." >&2; exit 1; }
git fetch origin "$BASE_BRANCH:$BASE_BRANCH" --quiet

# 2. If on a working branch, rebase onto the base branch
CURRENT=$(git branch --show-current)
if [[ "$CURRENT" == dev/* ]]; then
  git rebase "$BASE_BRANCH" --quiet || (git rebase --abort && git merge "$BASE_BRANCH" -m "Sync with $BASE_BRANCH")
fi

# 3. Memory — derive directory from egregore.json, never hardcode
MEMORY_DIR=$(basename "$(jq -r '.memory_repo' egregore.json)" .git)
if [ ! -L memory ]; then
  ln -s "../$MEMORY_DIR" memory
fi

# 4. Pull memory and capture what arrived
MEMORY_BEFORE=$(git -C memory rev-parse HEAD 2>/dev/null)
git -C memory pull origin main --quiet
MEMORY_AFTER=$(git -C memory rev-parse HEAD 2>/dev/null)

# 5. Show what arrived in memory (new/changed files since last pull)
if [ "$MEMORY_BEFORE" != "$MEMORY_AFTER" ]; then
  MEMORY_FILES=$(git -C memory diff --name-only "$MEMORY_BEFORE" "$MEMORY_AFTER")
  MEMORY_COUNT=$(echo "$MEMORY_FILES" | wc -l | tr -d ' ')
fi
```

## Output

Show what arrived — don't leave the user wondering if things synced:

```
Pulling...
  configured base ↓ 3 commits → synced
  dev/oz/...      ✓ rebased onto configured base
  memory         ↓ 2 commits — 4 files updated
                   handoffs/2026-02/12-renckorzay-giza-docs.md (new)
                   handoffs/index.md
                   artifacts/giza-architecture.md (new)
                   artifacts/giza-api-spec.md (new)
```

If memory is already up to date:
```
  memory         ✓ up to date
```
