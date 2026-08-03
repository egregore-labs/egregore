Stage changes and commit with a message.

Message (optional): $ARGUMENTS

## Loom routing

**Skip this section if your prompt contains `LOOM-EXECUTOR`** — you are the executor; run the skill as specced below. Full protocol: `.claude/context/loom.md`.

1. Resolve: `ROUTE=$(bash bin/loom.sh route commit)`, then `DECISION_ID=$(printf '%s\n' "$ROUTE" | jq -r '.decision_id // empty')`.
2. If `mode` ≠ `delegate`, or the user signalled depth ("deep", "think hard", `--deep`) → run this skill inline as normal. On a depth override, print `bash bin/loom.sh footer commit --override` after the output and set `"override":true` in telemetry.
3. Otherwise delegate: spawn the Agent tool with `subagent_type:
   "loom-executor"`, `model` = the route's `tier`, prompt =
   `LOOM-DECISION-ID: $DECISION_ID` on its own first line, then
   `LOOM-EXECUTOR: Execute .claude/skills/commit/SKILL.md`, plus the user's
   arguments and any context the spec needs from the session. Print the
   executor's final output **verbatim**, then print the output of
   `bash bin/loom.sh footer commit`.
4. If the spawn fails or the executor's first line is `LOW_CONFIDENCE:` —
   triage the reason: needs-user-interaction or a main-loop-only tool → take
   over and finish this skill inline (no escalation); genuine uncertainty or
   failure → reassign `ROUTE=$(bash bin/loom.sh escalate commit "<reason>")`,
   refresh `DECISION_ID` from `ROUTE`, then re-spawn once on the new tier
   carrying the returned decision ID
   (sticky for this session).
5. Telemetry (fire-and-forget):
   `bash bin/telemetry.sh emit "command" '{"command":"commit","routed":true,"mode":"delegate","model":"<actual>","route_tier":"<table tier>","class":"<class>","escalated":<bool>,"override":<bool>,"source":"<source>"}' 2>/dev/null &`

## Before anything else

Resolve `BASE_BRANCH` through `bin/lib/config.sh` → `_get_base_branch` (pass the managed repo name when applicable). Check `git branch --show-current`. If on a protected branch (`$BASE_BRANCH`, `develop`, `main`, or `master`):
  → Use the resolved base branch (default `"develop"`)
  → Create a working branch: `git fetch origin $BASE_BRANCH --quiet && git checkout -b dev/{author}/{topic-slug} origin/$BASE_BRANCH`
  → Tell the user: "Creating a working branch for this..." — never mention git commands to the user.
  → Then proceed with the commit.

## What to do

1. Show modified and untracked files
2. Stage relevant files (ignore build artifacts)
3. Prompt for or suggest commit message
4. Create the commit

## Example

```
> /commit

Checking changes...

Modified files:
  src/mcp/auth.py        (+42, -3)
  src/mcp/server.py      (+8, -2)
  tests/test_auth.py     (+28, new file)

Untracked:
  src/mcp/__pycache__/   (ignored ✓)

Staging modified files...
  git add src/mcp/auth.py src/mcp/server.py tests/test_auth.py

Enter commit message (or I can suggest one):
> Add MCP authentication with API key validation

  git commit -m "Add MCP authentication with API key validation"
  ✓ Committed (abc1234)

Changes committed locally. Run /push to share, or /pr when ready for review.
```

## With message argument

```
> /commit fix typo in readme

Staging and committing...
  git add -A
  git commit -m "fix typo in readme"
  ✓ Committed (def5678)
```

## Next

Run `/push` to share, or keep working and commit again.
