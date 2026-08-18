---
name: push
description: "Use for /push, or 'push my branch' — pushes the current branch to origin, setting upstream on first push, before opening a PR with /pr."
---

Push current branch to remote.

## When to invoke

User says: "/push", "push my branch", "push this up", "get my branch onto GitHub", or needs the current branch pushed to origin before opening a PR.
Not this: ready to open the PR itself → `/pr` (run after push).

## Loom routing

**Skip this section if your prompt contains `LOOM-EXECUTOR`** — you are the executor; run the skill as specced below. Full protocol: `.claude/context/loom.md`.

1. Resolve: `ROUTE=$(bash bin/loom.sh route push)`, then `DECISION_ID=$(printf '%s\n' "$ROUTE" | jq -r '.decision_id // empty')`.
2. If `mode` ≠ `delegate`, or the user signalled depth ("deep", "think hard", `--deep`) → run this skill inline as normal. On a depth override, print `bash bin/loom.sh footer push --override` after the output and set `"override":true` in telemetry.
3. Otherwise delegate: spawn the Agent tool with `subagent_type:
   "loom-executor"`, `model` = the route's `tier`, prompt =
   `LOOM-DECISION-ID: $DECISION_ID` on its own first line, then
   `LOOM-EXECUTOR: Execute .claude/skills/push/SKILL.md`, plus the user's
   arguments and any context the spec needs from the session. Print the
   executor's final output **verbatim**, then print the output of
   `bash bin/loom.sh footer push`.
4. If the spawn fails or the executor's first line is `LOW_CONFIDENCE:` —
   triage the reason: needs-user-interaction or a main-loop-only tool → take
   over and finish this skill inline (no escalation); genuine uncertainty or
   failure → reassign `ROUTE=$(bash bin/loom.sh escalate push "<reason>")`,
   refresh `DECISION_ID` from `ROUTE`, then re-spawn once on the new tier
   carrying the returned decision ID
   (sticky for this session).
5. Telemetry (fire-and-forget):
   `bash bin/telemetry.sh emit "command" '{"command":"push","routed":true,"mode":"delegate","model":"<actual>","route_tier":"<table tier>","class":"<class>","escalated":<bool>,"override":<bool>,"source":"<source>"}' 2>/dev/null &`

## Before anything else

Resolve `BASE_BRANCH` through `bin/lib/config.sh` → `_get_base_branch` (pass the managed repo name when applicable). Check `git branch --show-current`. If on a protected branch (`$BASE_BRANCH`, `develop`, `main`, or `master`):
  → Use the resolved base branch (default `"develop"`)
  → Create a working branch: `git fetch origin $BASE_BRANCH --quiet && git checkout -b dev/{author}/{topic-slug} origin/$BASE_BRANCH`
  → Tell the user: "Creating a working branch for this..." — never mention git commands to the user.
  → Then proceed with the push.

## What to do

1. Push current branch to origin
2. Set upstream if first push

## Example

```
> /push

Pushing feature/2026-01-20-mcp-authentication...

  git push -u origin feature/2026-01-20-mcp-authentication
  ✓ Pushed

Branch is now on GitHub.
Run /pr when ready for review.
```

## Next

Run `/pr` when ready for review.
