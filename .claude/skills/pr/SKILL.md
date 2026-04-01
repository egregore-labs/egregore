Create a pull request for current branch targeting develop.

## What to do

1. Determine which repo — if the user mentions a managed repo (listed in `egregore.json` → `repos[]`), create the PR there. Otherwise use the hub.
2. Summarize branch changes vs develop
3. Prompt for title and description
4. Create PR via GitHub CLI targeting develop: `gh pr create --base develop`
5. Track PR in graph (fire-and-forget):
   ```bash
   PROJ_HASH=$(echo -n "$(pwd)" | md5 2>/dev/null || echo -n "$(pwd)" | md5sum 2>/dev/null | cut -d' ' -f1)
   SID=$(cat "$HOME/.egregore/session-${PROJ_HASH}.id" 2>/dev/null || echo "")
   GH_USER=$(jq -r '.github_username // empty' .egregore-state.json 2>/dev/null)
   REPO_NAME=$(jq -r '.repo_name // "egregore"' egregore.json 2>/dev/null)
   bash bin/graph-op.sh create-pr "$SID" "$PR_NUMBER" "$REPO_NAME" "$GH_USER" "$PR_TITLE" 2>/dev/null &
   ```
   Where `$PR_NUMBER` is extracted from the `gh pr create` output URL.
6. Return PR URL
7. Do NOT auto-merge — explicit `/pr` means "please review this"

## Example

```
> /pr

Creating pull request...

Branch: feature/2026-01-20-mcp-authentication
Base: develop
Commits: 3 commits ahead of develop
Changes: +78 lines, -5 lines, 3 files

Title: Add MCP authentication with API key validation
       (from your last commit — edit? y/n)
> n

Description — summarize what this PR does:
> Adds API key validation to MCP server. Keys are checked against env var. Includes tests.

  Creating PR via GitHub CLI...
  gh pr create --base develop --title "..."
  ✓ PR #42 created: https://github.com/{github_org}/egregore-core/pull/42

PR targeting develop — ready for review.
When merged, oz can /release to main.
```

## Next

Share the PR link. Run `/handoff` if ending your session.
