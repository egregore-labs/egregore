---
name: pr
description: "Use for /pr, or 'create a PR' / 'open a pull request' — creates a pull request for the current branch against the repo's base branch with a formatted title and body. Not for reviewing an existing PR (review-pr)."
---

Create a pull request for current branch targeting the repo's base branch.

## When to invoke

User says: "/pr", "create a PR", "open a pull request", "push this up for review", or the current branch is ready to be reviewed against the base branch.
Not this: reviewing an existing PR → `/review-pr`.

## Execution boundary

The Git and GitHub mechanics are deterministic and run inline. The main loop
keeps only the judgment work: summarize the diff, draft the review text, and
show the exact title/body before the external PR creation.

## What to do

1. Determine which repo — if the user mentions a managed repo (listed in `egregore.json` → `repos[]`), create the PR there. Otherwise use the hub.
2. Resolve the configured integration branch first:
   ```bash
   bash bin/base-branch.sh
   ```
   It prints the branch name; for a managed repo run `bash bin/base-branch.sh <repo-name>`.
   A non-zero exit means the configuration could not be resolved: stop before any
   Git change. Use the printed name wherever `{base}` appears below.
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
5. Create PR via GitHub CLI: `gh pr create --base "{base}" --title "$TITLE" --body "$BODY"` — never `--fill`, never an empty body (the `pr-format` CI check fails bare PRs)
6. Track PR in graph (fire-and-forget):
   ```bash
   bash bin/graph-op.sh record-pr <number> "<title>" 2>/dev/null &
   ```
   `<number>` comes from the `gh pr create` output URL; the command resolves
   the session, repository, and author itself.
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
