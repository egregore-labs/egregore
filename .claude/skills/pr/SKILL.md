---
name: pr
description: "Use for /pr, or 'create a PR' / 'open a pull request' — creates a pull request for the current branch against the repo's base branch with a formatted title and body. Not for reviewing an existing PR (review-pr)."
---

Create a pull request for current branch targeting the repo's base branch.

## When to invoke

User says: "/pr", "create a PR", "open a pull request", "push this up for review", or the current branch is ready to be reviewed against the base branch.
Not this: reviewing an existing PR → `/review-pr`.

## Loom routing

**Skip this section if your prompt contains `LOOM-EXECUTOR`** — you are the executor; run the skill as specced below. Full protocol: `.claude/context/loom.md`.

1. Resolve: `ROUTE=$(bash bin/loom.sh route pr)`, then `DECISION_ID=$(printf '%s\n' "$ROUTE" | jq -r '.decision_id // empty')`.
2. If `mode` ≠ `delegate`, or the user signalled depth ("deep", "think hard", `--deep`) → run this skill inline as normal. On a depth override, print `bash bin/loom.sh footer pr --override` after the output and set `"override":true` in telemetry.
3. Otherwise delegate: spawn the Agent tool with `subagent_type:
   "loom-executor"`, `model` = the route's `tier`, prompt =
   `LOOM-DECISION-ID: $DECISION_ID` on its own first line, then
   `LOOM-EXECUTOR: Execute .claude/skills/pr/SKILL.md`, plus the user's
   arguments and any context the spec needs from the session. Print the
   executor's final output **verbatim**, then print the output of
   `bash bin/loom.sh footer pr`.
4. If the spawn fails or the executor's first line is `LOW_CONFIDENCE:` —
   triage the reason: needs-user-interaction or a main-loop-only tool → take
   over and finish this skill inline (no escalation); genuine uncertainty or
   failure → reassign `ROUTE=$(bash bin/loom.sh escalate pr "<reason>")`,
   refresh `DECISION_ID` from `ROUTE`, then re-spawn once on the new tier
   carrying the returned decision ID
   (sticky for this session).
5. Telemetry (fire-and-forget):
   `bash bin/telemetry.sh emit "command" '{"command":"pr","routed":true,"mode":"delegate","model":"<actual>","route_tier":"<table tier>","class":"<class>","escalated":<bool>,"override":<bool>,"source":"<source>"}' 2>/dev/null &`

## What to do

1. Determine which repo — if the user mentions a managed repo (listed in `egregore.json` → `repos[]`), create the PR there. Otherwise use the hub.
2. Resolve the target base branch:
   - **Egregore hub repo**: call `_get_base_branch`
   - **Managed repos**: call `_get_base_branch "$REPO"`
   - Both use the validated `base_branch` from `egregore.json`; a valid config
     that omits it defaults to `"develop"`, while resolution errors stop
     before Git changes.
     ```bash
     BASE_BRANCH=$(bash -c 'SCRIPT_DIR="$PWD"; CONFIG="$PWD/egregore.json"; . "$PWD/bin/lib/config.sh" && _get_base_branch "$1"' _ "${REPO:-}") ||
       { echo "Could not resolve the configured base branch; stopping before Git changes." >&2; exit 1; }
     ```
3. Summarize branch changes vs base branch
4. Draft title and body per `.claude/context/pr-format.md`:
   - Title: `type(scope): imperative summary` (≤ 72 chars) — the same
     grammar as commit subjects (`.claude/context/commit-format.md`).
     A single-commit PR reuses its commit subject verbatim when it
     describes the whole PR.
   - Body: `## What` (1–4 bullets) · `## Why` (1–3 sentences) ·
     `## Verification` (how it was checked — required when the diff touches
     non-markdown files; be honest if unverified) · `## Risk` / `## Links`
     when real · attribution footer of the harness that authored the body
     (final non-blank line, e.g. `🤖 Generated with [Claude Code](https://claude.com/claude-code)`)
   - Show the draft to the user; apply their edits before creating
5. Create PR via GitHub CLI: `gh pr create --base "$BASE_BRANCH" --title "$TITLE" --body "$BODY"` — never `--fill`, never an empty body (the `pr-format` CI check fails bare PRs)
6. Track PR in graph (fire-and-forget):
   ```bash
   PROJ_HASH=$(echo -n "$(pwd)" | md5 2>/dev/null || echo -n "$(pwd)" | md5sum 2>/dev/null | cut -d' ' -f1)
   SID=$(cat "$HOME/.egregore/session-${PROJ_HASH}.id" 2>/dev/null || echo "")
   GH_USER=$(jq -r '.github_username // empty' .egregore-state.json 2>/dev/null)
   REPO_NAME=$(jq -r '.repo_name // "egregore"' egregore.json 2>/dev/null)
   bash bin/graph-op.sh create-pr "$SID" "$PR_NUMBER" "$REPO_NAME" "$GH_USER" "$PR_TITLE" 2>/dev/null &
   ```
   Where `$PR_NUMBER` is extracted from the `gh pr create` output URL.
7. Return PR URL
8. Do NOT auto-merge — explicit `/pr` means "please review this"

## Example

```
> /pr

Creating pull request...

Branch: feature/2026-01-20-mcp-authentication
Base: main
Commits: 3 commits ahead of main
Changes: +78 lines, -5 lines, 3 files

Title: feat(mcp): add API key authentication
       (from your last commit — edit? y/n)
> n

Description — summarize what this PR does:
> Adds API key validation to MCP server. Keys are checked against env var. Includes tests.

  Creating PR via GitHub CLI...
  gh pr create --base main --title "..."
  ✓ PR #42 created: https://github.com/{github_org}/myapp/pull/42

PR targeting main — ready for review.
```

## Next

Share the PR link. Run `/handoff` if ending your session.
