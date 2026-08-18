---
name: sync-repos
description: "Smart sync of all Egregore repos (memory + managed repos + current repo) — fetches first, only pulls if behind. Use for /sync-repos or 'sync all repos'."
---

Smart sync of all Egregore repos. Fetches first, only pulls if behind.

## When to invoke

User says: "/sync-repos", "sync all repos", "sync everything", "get every repo up to date"

## Loom routing

**Skip this section if your prompt contains `LOOM-EXECUTOR`** — you are the executor; run the skill as specced below. Full protocol: `.claude/context/loom.md`.

1. Resolve: `ROUTE=$(bash bin/loom.sh route sync-repos)`, then `DECISION_ID=$(printf '%s\n' "$ROUTE" | jq -r '.decision_id // empty')`.
2. If `mode` ≠ `delegate`, or the user signalled depth ("deep", "think hard", `--deep`) → run this skill inline as normal. On a depth override, print `bash bin/loom.sh footer sync-repos --override` after the output and set `"override":true` in telemetry.
3. Otherwise delegate: spawn the Agent tool with `subagent_type:
   "loom-executor"`, `model` = the route's `tier`, prompt =
   `LOOM-DECISION-ID: $DECISION_ID` on its own first line, then
   `LOOM-EXECUTOR: Execute .claude/skills/sync-repos/SKILL.md`, plus the user's
   arguments and any context the spec needs from the session. Print the
   executor's final output **verbatim**, then print the output of
   `bash bin/loom.sh footer sync-repos`.
4. If the spawn fails or the executor's first line is `LOW_CONFIDENCE:` —
   triage the reason: needs-user-interaction or a main-loop-only tool → take
   over and finish this skill inline (no escalation); genuine uncertainty or
   failure → reassign `ROUTE=$(bash bin/loom.sh escalate sync-repos "<reason>")`,
   refresh `DECISION_ID` from `ROUTE`, then re-spawn once on the new tier
   carrying the returned decision ID
   (sticky for this session).
5. Telemetry (fire-and-forget):
   `bash bin/telemetry.sh emit "command" '{"command":"sync-repos","routed":true,"mode":"delegate","model":"<actual>","route_tier":"<table tier>","class":"<class>","escalated":<bool>,"override":<bool>,"source":"<source>"}' 2>/dev/null &`

## Repos to sync

- `../$MEMORY_DIR` — shared knowledge (derived from `memory_repo` in `egregore.json`)
- Any repos listed in the `repos` array in `egregore.json` (as sibling directories `../{repo}`)
- Current repo (egregore-core)

**Read `egregore.json` first** to get the dynamic list:
```bash
# Memory repo directory
MEMORY_DIR=$(basename "$(jq -r '.memory_repo' egregore.json)" .git)

# Managed repos
REPOS=$(jq -r '.repos[]? // empty' egregore.json)
```

## Execution

For each repo, run these commands:

```bash
# 1. Fetch (always)
git -C /path/to/repo fetch origin --quiet

# 2. Compare local vs remote
LOCAL=$(git -C /path/to/repo rev-parse HEAD)
REMOTE=$(git -C /path/to/repo rev-parse origin/main)

# 3. Only pull if different
if [ "$LOCAL" != "$REMOTE" ]; then
  git -C /path/to/repo pull origin main --quiet
  # Count commits behind
  BEHIND=$(git -C /path/to/repo rev-list HEAD..origin/main --count)
fi
```

**For the current repo (egregore-core)**: sync the `develop` branch instead of main:
```bash
# Update local develop ref without switching branches (safe for concurrent sessions)
git fetch origin develop:develop --quiet
# If on dev/* branch, rebase onto develop
BRANCH=$(git branch --show-current)
if [[ "$BRANCH" == dev/* ]]; then
  git rebase develop --quiet || (git rebase --abort && git merge develop -m "Sync with develop")
fi
```

Use absolute paths with `git -C` to avoid permission prompts.

## Output format

```
Syncing Egregore repos...

  {memory-dir}       ↓ 3 commits → pulled
  {repo-1}           ✓ up to date
  {repo-2}           ✓ up to date
  egregore-core      ↓ 1 commit → pulled
```

## Rules

- Use `git -C /absolute/path` — no `cd` commands
- Fetch ALL repos first (parallel if possible), then compare/pull
- Show commit count when pulling
- Skip repos that don't exist (no error)
