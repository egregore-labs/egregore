Save your contributions to Egregore. Pushes working branch, creates PR to develop.

**Worktree note:** Git operations (commit, push, `gh pr create`) work normally from within a worktree — no special handling needed. After save completes, work continues in the worktree. Worktree cleanup happens automatically when the session ends (WorktreeRemove hook), never during an active session.

## When to invoke

User says: "push my work", "sync changes", "commit and push", "save everything", "push this up"
Not this: user is leaving/done → `/handoff` (which auto-saves)

## Mode detection

```bash
MODE=$(jq -r '.mode // "connected"' egregore.json 2>/dev/null)
```

**Local mode** (`mode === "local"`): Skip the "Sync to Neo4j" step entirely. Skip `bin/sync-graph.sh` and the graph enrichment section. Skip the `bash bin/graph-op.sh create-pr ...` fire-and-forget calls. Do NOT show any graph-related messaging ("[sync] Checking Neo4j...", "Synced N to graph", "tracked PR in graph", etc.). Git operations (commit, push, `gh pr create`) work identically in both modes — only the graph reporting layer is skipped.

## Execution rules

**CRITICAL: Suppress raw output.** Never show raw JSON to the user. All `bin/graph.sh` calls MUST capture output in a variable and only show formatted status lines (e.g. "Synced 2 sessions, 1 artifact to graph").

## What to do

### Step 0: Branch health check

Before saving, verify the current branch is still valid:

```bash
CURRENT_BRANCH=$(git branch --show-current)
```

**Case A: On a protected branch (develop/main)** — the user should not be here. Create a working branch:
1. Derive a topic slug from conversation context or recent commits
2. `git fetch origin develop --quiet && git checkout -b dev/$AUTHOR/$TOPIC_SLUG origin/develop`
3. Continue with save

**Case B: Remote branch gone (PR was merged)** — detect with:
```bash
git fetch origin --prune --quiet 2>/dev/null
git ls-remote --heads origin "$CURRENT_BRANCH" 2>/dev/null | grep -q "$CURRENT_BRANCH"
```
If the remote branch is gone:
1. Use AskUserQuestion to ask:
   > Your branch `$CURRENT_BRANCH` was merged to develop. What's next?
   - **"Working on something new"** → ask what they're working on, derive topic slug, create `dev/$AUTHOR/$NEW_SLUG` in the same worktree
   - **"I'm done for now"** → session continues normally, worktree cleaned up on exit
2. If in a worktree, stay in the same worktree — just switch branches within it
3. Continue with save on the new branch

**Case C: Branch exists and is healthy** — proceed normally.

1. **Sync to Neo4j first** (CRITICAL):
   - Scan memory/handoffs/ for files without Session nodes
   - Scan memory/artifacts/ for files without Artifact nodes
   - Scan memory/knowledge/decisions/ for files without Artifact nodes
   - Scan memory/knowledge/findings/ for files without Artifact nodes
   - Scan memory/knowledge/patterns/ for files without Artifact nodes
   - Scan memory/quests/ for files without Quest nodes
   - Create missing nodes automatically
   - Report: "Synced 2 sessions, 1 artifact to graph"

2. **For memory repo** (artifacts, quests, handoffs):
   - Push directly to main (no PRs — memory is markdown-only, always safe to merge)
   - Pull-rebase-push with retry to handle concurrent pushes from other users
   ```bash
   cd memory
   git add -A
   git commit -m "$COMMIT_MESSAGE"
   # Retry loop: handles concurrent pushes from other users
   for i in 1 2 3; do
     git -c rebase.empty=drop pull --rebase origin main --quiet && git push origin main --quiet && break
     if [ $i -eq 3 ]; then
       echo "Push failed after 3 attempts. Try /save again."
       exit 1
     fi
     sleep 1
   done
   cd -
   ```
   - User sees: "Memory pushed"

3. **For egregore** (commands, scripts, config):
   - Ensure on a working branch (`dev/*`, `feature/*`, or `bugfix/*`). If not (e.g. still on develop), create one:
     - Derive a topic slug from the changes being saved (look at modified files, commit messages, or conversation context)
     - Create branch: `dev/$AUTHOR/{topic-slug}` from develop
     - If no clear topic, fall back to date: `dev/$AUTHOR/$(date +%Y-%m-%d)`
     ```bash
     git fetch origin develop --quiet
     git checkout -b dev/$AUTHOR/$TOPIC_SLUG origin/develop
     ```
   - Commit all changes to working branch
   - **Rebase onto latest develop before pushing** (prevents stale overwrites):
     ```bash
     git fetch origin develop --quiet
     git rebase origin/develop --quiet --empty=drop
     ```
     If rebase conflicts: abort, try merge instead:
     ```bash
     git rebase --abort
     git merge origin/develop --quiet -m "Sync with develop"
     ```
     If merge also conflicts: stop and tell the user:
     > Your branch conflicts with develop. Run `git status` to see conflicts, resolve them, then `/save` again.
   - Push working branch:
     ```bash
     git push -u origin $BRANCH
     ```
   - **If push fails**: stop here. Do NOT proceed. Tell the user:
     > Push failed. Your commits are safe on your working branch. Check your network and try `/save` again.
   - Check for an existing open PR on this branch before creating (dedupe):
     ```bash
     EXISTING_PR=$(gh pr list --head "$BRANCH" --state open --json number,baseRefName --jq '.[0]' 2>/dev/null)
     EXISTING_NUMBER=$(echo "$EXISTING_PR" | jq -r '.number // empty')
     EXISTING_BASE=$(echo "$EXISTING_PR" | jq -r '.baseRefName // empty')
     ```
     - **If an open PR exists with base `develop`** → reuse it. Set `PR_NUMBER=$EXISTING_NUMBER` and skip `gh pr create`. Tell the user: `Updated existing PR #$PR_NUMBER`.
     - **If an open PR exists with a different base** (e.g. `main`) → retarget it rather than open a second one:
       ```bash
       gh pr edit "$EXISTING_NUMBER" --base develop
       ```
       Set `PR_NUMBER=$EXISTING_NUMBER`. Tell the user: `Retargeted PR #$PR_NUMBER to develop`.
     - **If no open PR exists** → create one (always pass `--base` explicitly so `gh` never falls back to the repo's default branch):
       ```bash
       gh pr create --base develop --title "..." --body "..."
       ```
   - **If PR creation fails**: stop here. The branch was pushed, so tell the user:
     > PR creation failed, but your branch `{BRANCH}` was pushed.
     > Your commits are safe. Try again with `/save` or create the PR manually.
   - **If PR succeeds**, track it in the graph (fire-and-forget, must not delay response):
     ```bash
     PROJ_HASH=$(echo -n "$(pwd)" | md5 2>/dev/null || echo -n "$(pwd)" | md5sum 2>/dev/null | cut -d' ' -f1)
     SID=$(cat "$HOME/.egregore/session-${PROJ_HASH}.id" 2>/dev/null || echo "")
     GH_USER=$(jq -r '.github_username // empty' .egregore-state.json 2>/dev/null)
     REPO_NAME=$(jq -r '.repo_name // "egregore"' egregore.json 2>/dev/null)
     bash bin/graph-op.sh create-pr "$SID" "$PR_NUMBER" "$REPO_NAME" "$GH_USER" "$PR_TITLE" 2>/dev/null &
     ```
     Where `$PR_NUMBER` is extracted from the `gh pr create` output (parse the URL for the number).
   - Then detect if markdown-only or has code:
     ```bash
     NON_MD=$(git diff develop --name-only | grep -v '\.md$' | head -1)
     ```
     - **Markdown-only** (NON_MD is empty) → `gh pr merge --auto --merge` → auto-merges
     - **Has code/config changes** → run preflight check, then leave PR open for review:
       ```bash
       bash bin/preflight.sh
       ```
       - If preflight **passes** (exit 0) → show `✓ Preflight passed` and create PR normally
       - If preflight **fails** (exit 1) → show violations, still create PR but add `⚠ preflight-failed` label:
         ```bash
         gh pr edit $PR_NUMBER --add-label "preflight-failed"
         ```
         Tell the developer: `⚠ Preflight found issues — fix before merging. See violations above.`
       - Preflight never blocks the save — work is always preserved. It warns.
     - **Cypher query check** — after preflight, detect if changed files contain Cypher blocks:
       ```bash
       git diff develop --name-only | xargs grep -l '```cypher' 2>/dev/null | head -1
       ```
       If any files contain Cypher blocks, show a non-blocking recommendation:
       > Changed files contain Cypher queries. Consider running `/test` first.
       This is advisory only — never blocks the save.

4. **For managed repos** (listed in `egregore.json` → `repos[]`, located at `../{repo}/`):
   - Read the repos list and resolve each repo's base branch:
     ```bash
     # Get repo name (supports both string and object format)
     REPO_NAME=$(jq -r '(.repos[]? // empty) | if type == "object" then .name else . end' egregore.json)
     # Get base branch for a repo (object format has base_branch, default "develop")
     BASE_BRANCH=$(jq -r --arg name "$REPO" '(.repos[]? // empty) | select((if type == "object" then .name else . end) == $name) | if type == "object" then .base_branch // "develop" else "develop" end' egregore.json)
     ```
   - For each repo, check for uncommitted changes:
     ```bash
     REPO_DIR="$(cd .. && pwd)/$REPO"
     if [ -n "$(git -C "$REPO_DIR" status --porcelain)" ]; then
       # Has changes
     fi
     ```
   - **If no changes in any repo**, skip silently
   - **If changes exist**, handle each repo using its base branch (NOT hardcoded develop):
     1. Ensure on a working branch. If on the base branch (main/develop/master), create one:
        ```bash
        git -C "$REPO_DIR" fetch origin "$BASE_BRANCH" --quiet
        git -C "$REPO_DIR" checkout -b dev/$AUTHOR/$TOPIC_SLUG "origin/$BASE_BRANCH"
        ```
        Derive topic slug from conversation context or changed files. Fall back to date.
     2. Stage and commit changes:
        ```bash
        git -C "$REPO_DIR" add -A
        git -C "$REPO_DIR" commit -m "$COMMIT_MESSAGE"
        ```
     3. Rebase onto latest base branch before pushing:
        ```bash
        git -C "$REPO_DIR" fetch origin "$BASE_BRANCH" --quiet
        git -C "$REPO_DIR" rebase "origin/$BASE_BRANCH" --quiet
        ```
        If rebase conflicts: abort, try merge:
        ```bash
        git -C "$REPO_DIR" rebase --abort
        git -C "$REPO_DIR" merge "origin/$BASE_BRANCH" --quiet -m "Sync with $BASE_BRANCH"
        ```
        If merge also conflicts: stop and tell the user.
     4. Push working branch:
        ```bash
        git -C "$REPO_DIR" push -u origin $BRANCH
        ```
     5. Check for an existing open PR on this branch before creating (dedupe), then create or retarget:
        ```bash
        EXISTING_PR=$(gh pr list --repo "$GITHUB_ORG/$REPO" --head "$BRANCH" --state open --json number,baseRefName --jq '.[0]' 2>/dev/null)
        EXISTING_NUMBER=$(echo "$EXISTING_PR" | jq -r '.number // empty')
        EXISTING_BASE=$(echo "$EXISTING_PR" | jq -r '.baseRefName // empty')
        ```
        - If open PR exists with base `$BASE_BRANCH` → reuse: `PR_NUMBER=$EXISTING_NUMBER`, skip create, message `Updated existing PR #$PR_NUMBER`.
        - If open PR exists with a different base → retarget rather than duplicate:
          ```bash
          gh pr edit "$EXISTING_NUMBER" --repo "$GITHUB_ORG/$REPO" --base "$BASE_BRANCH"
          ```
          Set `PR_NUMBER=$EXISTING_NUMBER`, message `Retargeted PR #$PR_NUMBER to $BASE_BRANCH`.
        - If no open PR exists → create (always pass `--base` explicitly):
          ```bash
          gh pr create --repo "$GITHUB_ORG/$REPO" --base "$BASE_BRANCH" --title "..." --body "..."
          ```
     6. Track PR in graph (fire-and-forget):
        ```bash
        bash bin/graph-op.sh create-pr "$SID" "$PR_NUMBER" "$REPO" "$GH_USER" "$PR_TITLE" 2>/dev/null &
        ```
     7. User sees: `[repo-name] ✓ Pushed dev/alice/topic-slug → PR #N to $BASE_BRANCH`
   - **Use `git -C` with absolute paths** — never `cd` into the repo (avoids permission prompts)

## Neo4j Sync Logic

### Artifact property contract

Every Artifact node MUST have: `id`, `title`, `type`, `topics`, `created`. SHOULD have: `filePath`. MAY have: `origin`, `analysis`, `runId`, `confidence`, dimensional properties.

Commands that create artifacts: `/add`, `/reflect`, `/deep-reflect`, `/tutorial`, `/meeting`, `/save` sync. All must set the MUST properties. If a session creates ad-hoc artifacts (e.g., session synthesis), it must follow this contract.

```bash
RESULT=$(bash bin/sync-graph.sh 2>/dev/null) && echo "OK" || echo "FAILED"
```

The script handles everything: fetches existing IDs from the graph, scans all memory files (handoffs, knowledge/decisions, knowledge/findings, knowledge/patterns, quests), creates missing nodes via MERGE (idempotent), auto-resolves `read` handoffs, and derives quest topics from linked artifacts.

Returns: `{"sessions":N,"artifacts":N,"quests":N,"resolved":N}`

Parse the result and show:
- If any counts > 0: `[sync] Synced N sessions, N artifacts, N quests to graph`
- If resolved > 0, add: `[sync] ✓ Resolved N handoffs (read → done)`
- If all zeros: `[sync] ✓ Nothing to sync`
- If script fails: `[sync] Graph offline — will retry on next /save`. Don't block git operations.

This ensures files and graph stay in sync even if earlier commands skipped Neo4j.

### Metadata enrichment for existing artifacts

After all node creation and topic sync, enrich artifacts with missing metadata.

**Topics backfill:**

```cypher
MATCH (a:Artifact)
WHERE a.topics IS NULL OR size(a.topics) = 0
RETURN a.id AS id, a.title AS title, a.type AS type, a.filePath AS filePath
```

For each artifact returned:
1. **Has filePath** → read `memory/{filePath}`, parse frontmatter for `topics:`. If found, SET on node.
2. **Has filePath but no frontmatter topics** → derive 2-4 topic slugs from title (lowercase, exclude stop words like "the/a/an/is/for/and/or/in/of/to", hyphenate compounds). Example: "Egregore Efficiency and Unit Economics" → `["egregore-efficiency", "unit-economics"]`.
3. **No filePath (ghost artifact)** → derive topics from title only (same method as #2).
4. Run: `MATCH (a:Artifact {id: $id}) SET a.topics = $topics`

**Type backfill:**

```cypher
MATCH (a:Artifact) WHERE a.type IS NULL
RETURN a.id AS id, a.title AS title, a.filePath AS filePath
```

Derive type from:
- filePath directory: `decisions/` → `decision`, `findings/` → `finding`, `patterns/` → `pattern`
- Title cues if no filePath: "confirmed"/"strategy"/"chose"/"decided" → `decision`, "risk"/"crisis"/"discovered"/"observed" → `finding`, "pattern"/"loop"/"recurring"/"tendency" → `pattern`
- Default: `"finding"`
- Run: `MATCH (a:Artifact {id: $id}) SET a.type = $type`

Report: `[sync] ✓ Enriched {N} artifacts (topics: {n1}, type: {n2})`

### Timestamp normalization

Normalize null `created` timestamps so sort order is reliable:

```cypher
MATCH (a:Artifact) WHERE a.created IS NULL
RETURN a.id AS id, a.filePath AS filePath
```

For each: extract date from:
1. Artifact ID if it has `YYYY-MM-DD` prefix (e.g. `2026-02-07-some-title` → `2026-02-07`)
2. Frontmatter `date:` field (if filePath exists, read the file)
3. Git log: `git log --format=%aI --diff-filter=A -- "memory/{filePath}" | head -1` (file creation date)
4. Fallback: use `2026-01-01` (sorts to end, identifiable as backfilled)

Normalize to datetime:
```cypher
MATCH (a:Artifact {id: $id}) SET a.created = datetime($isoDateStr + 'T00:00:00Z')
```

Report: `[sync] ✓ Normalized {N} timestamps`

### Ghost artifact resolution

Resolve filePaths for graph-only artifacts that may have been materialized since creation:

```cypher
MATCH (a:Artifact) WHERE a.filePath IS NULL AND a.type IS NOT NULL
RETURN a.id AS id, a.type AS type
```

For each: search filesystem by convention:
```bash
for dir in "knowledge/decisions" "knowledge/findings" "knowledge/patterns" "artifacts"; do
  [ -f "memory/${dir}/${ID}.md" ] && FOUND="${dir}/${ID}.md" && break
done
```

If found: `MATCH (a:Artifact {id: $id}) SET a.filePath = $found`
If not found: leave null — `/deep-reflect` handles ghost artifacts gracefully via metadata-only evidence entries (see deep-reflect.md Step 3B section 4).

Report: `[sync] ✓ Resolved {N} ghost artifact paths`

**Note:** ~39 of the 53 ghost artifacts genuinely have no file. They're session-extracted insights written to the graph but never materialized as markdown. This is expected — the enrichment steps above ensure they at least have topics, type, and created set.

## Example

```
> /save

Saving to Egregore...

[sync] Checking Neo4j...
  handoffs/2026-02/07-alice-infra-fix.md → missing Session
  ✓ Created Session node for alice
  Synced: 1 session

[memory]
  Changes:
    handoffs/2026-02/07-alice-infra-fix.md (new)
    handoffs/index.md (modified)

  Pushing to main...
    git commit -m "Add: handoff for infra fix"
    git -c rebase.empty=drop pull --rebase origin main
    git push origin main

  ✓ Memory pushed

[egregore]
  On branch: dev/alice/2026-02-07-session
  Changes:
    .claude/commands/save.md (modified)
    bin/session-start.sh (new)

  Pushing and creating PR...
    git push -u origin dev/alice/2026-02-07-session
    gh pr create --base develop --title "Update save command and add session-start"

  Has code changes — PR #15 created for review.
  ✓ Notified alice

Done. Team sees your contribution on /activity.
```

## With managed repo changes

```
> /save

Saving to Egregore...

[sync] Checking Neo4j...
  ✓ Nothing to sync

[memory]
  No changes.

[egregore]
  No changes.

[frontend]
  On branch: develop → creating dev/alice/auth-flow
  Changes:
    src/auth/token.ts      (+18, -3)
    src/auth/middleware.ts  (+42, new file)

  Rebasing onto develop...
    ✓ Clean rebase

  Pushing and creating PR...
    git push -u origin dev/alice/auth-flow
    gh pr create --repo acme-org/frontend --base develop
    ✓ PR #27 created for review

Done.
```

## Markdown-only egregore PR (auto-merges)

```
[egregore]
  On branch: dev/bob/2026-02-08-session
  Changes:
    .claude/commands/onboarding.md (modified)

  Pushing and creating PR...
    gh pr create --base develop
    gh pr merge --auto --merge

  ✓ Markdown-only — auto-merged to develop
```

## If no changes

```
> /save

No uncommitted changes.
```

## Site change detection

After saving changes to the hub repo, check if any files in `site 2/` were modified in the commits being saved:

```bash
# Check if any staged/committed files touch site 2/
git diff develop --name-only | grep '^site 2/' | head -1
```

If there are changes in `site 2/`, print after the save summary:

```
Site changes detected in site 2/. Run /deploy-site to publish to egregore.xyz
```

Do NOT auto-deploy. Explicit is better than implicit for production deploys.

## Why this flow?

- Non-technical users never see git complexity
- Memory pushes directly to main (instant availability, no PR delay)
- Pull-rebase-push retry handles concurrent users safely
- Egregore markdown changes auto-merge to develop via PR
- Code/config changes get reviewed before merging to develop
- `/activity` shows contributions clearly
- `/release` controls what reaches main

## Next

Run `/activity` to see your contribution, or keep working.
