---
name: commit
description: "Stage changes and create a commit with a properly formatted message. Use for /commit, or saving work locally — not sharing it (/push) or opening a pull request (/pr)."
---

Stage changes and commit with a message.

## When to invoke

User says: "/commit", "commit this", "stage and commit", "save this change locally"
Not this: sharing your commit with others → `/push` · opening a pull request → `/pr`

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
3. Compose the message per the convention below — suggest one derived
   from the diff, or take the user's and align it to the convention
4. Create the commit

## Message convention

Full spec: `.claude/context/commit-format.md`. Wording:
`.claude/context/git-language.md`. The short form:

- Subject `type(scope): imperative summary` — ≤ 72 chars (aim ≤ 50),
  lowercase, no trailing period. Same grammar and type set as PR
  titles. It completes "if applied, this commit will ___".
- Body (when the diff cannot explain its own motivation): blank line
  after the subject, wrapped at 72, what and why — never how.
- Agent-authored commits end with a trailer block as the final
  paragraph:

  ```bash
  SID=$(cat .egregore-session-id 2>/dev/null)
  git commit -m "feat(mcp): add API key authentication" -m "Egregore-Session: $SID
  Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
  ```

  Omit the `Egregore-Session` line when the file is absent; use your
  harness's own identity line. Humans committing by hand skip
  trailers.
- One logical change per commit — split when the parts are
  independently revertable.

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
> feat(mcp): add API key authentication

  git commit -m "feat(mcp): add API key authentication"  # + trailer block
  ✓ Committed (abc1234)

Changes committed locally. Run /push to share, or /pr when ready for review.
```

## With message argument

```
> /commit docs(readme): fix typo

Staging and committing...
  git add -A
  git commit -m "docs(readme): fix typo"
  ✓ Committed (def5678)
```

## Next

Run `/push` to share, or keep working and commit again.
