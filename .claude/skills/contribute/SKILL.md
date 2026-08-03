Contribute an improvement back to the upstream Egregore framework.

Arguments: $ARGUMENTS

## When to invoke

User says: "I want to improve this command", "submit a fix upstream", "contribute back",
"send this to egregore", "contribute to the framework", "upstream PR", "fix in upstream"
Not this: saving work to org repo → `/save` · filing a bug → `/issue` · syncing from upstream → `/update`

## Argument routing

Parse `$ARGUMENTS`:

- **Empty** → Interactive mode (ask what they want to improve)
- `submit` → Submit mode (push changes + create cross-fork PR)
- `status` → Show current contribution state
- **Anything else** → Interactive mode with topic pre-seeded from arguments

## Step 0: Gate check

```bash
UPSTREAM_URL=$(jq -r '.upstream_url // empty' egregore.json 2>/dev/null)
```

**If `"none"`**: This is the upstream repo itself. Tell the user:

> This is the upstream repo. Use `/save` to push changes to develop.

Stop.

**If empty**: Default to `egregore-labs/egregore`.

Extract upstream org/repo:
```bash
[ -z "$UPSTREAM_URL" ] && UPSTREAM_URL="https://github.com/egregore-labs/egregore.git"
UPSTREAM_REPO=$(echo "$UPSTREAM_URL" | sed 's|.*github.com/||; s|\.git$||')
```

## Step 1: Check auth + get username

```bash
GH_USER=$(gh api user --jq '.login' 2>/dev/null)
```

If empty: "Run `bash bin/github-auth.sh` first — you need GitHub access to contribute." Stop.

---

## Interactive mode (default / topic provided)

### Step 2: Understand intent

If `$ARGUMENTS` is non-empty (and not `submit`/`status`), use as the topic description.

If empty, use AskUserQuestion:

```
header: "Contribute"
question: "What do you want to improve in the Egregore framework?"
options:
  - label: "A command"
    description: "Improve or fix a slash command"
  - label: "A script"
    description: "Improve or fix a bin/ script"
  - label: "CLAUDE.md"
    description: "Update framework behavior"
  - label: "Something else"
    description: "I'll describe what I want to change"
```

If freeform or "Something else" → ask the user to describe the change.

### Step 3: Set up infrastructure (silent — no output to user)

All three steps in one bash call:

```bash
# 3a: Fork upstream (idempotent — no-ops if fork exists)
gh repo fork "$UPSTREAM_REPO" --clone=false 2>/dev/null || true

# 3b: Add contribute remote (skip if exists)
if ! git remote get-url contribute &>/dev/null; then
  REPO_NAME=$(echo "$UPSTREAM_REPO" | cut -d'/' -f2)
  git remote add contribute "https://github.com/${GH_USER}/${REPO_NAME}.git" 2>/dev/null
fi
git fetch contribute --quiet 2>/dev/null || true

# 3c: Create contribution branch from upstream/main
git fetch upstream main --quiet 2>/dev/null || true
```

Derive topic slug:
```bash
SLUG=$(echo "$DESCRIPTION" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//' | cut -c1-40)
CONTRIBUTE_BRANCH="contribute/${SLUG}"
```

Save current branch for later return:
```bash
PREVIOUS_BRANCH=$(git branch --show-current)
```

Check if branch exists:
```bash
if git show-ref --verify --quiet "refs/heads/$CONTRIBUTE_BRANCH" 2>/dev/null; then
  # Branch exists — ask: resume or start fresh?
fi
```

If new:
```bash
git checkout -b "$CONTRIBUTE_BRANCH" upstream/main --quiet
```

### Step 4: Confirm setup

```
Contributing to {UPSTREAM_REPO}

  Fork:   github.com/{GH_USER}/{repo_name}
  Branch: {CONTRIBUTE_BRANCH}
  Scope:  bin/ · .claude/commands/ · .claude/agents/ · loom/ · CLAUDE.md · skills/

Make your changes, then run /contribute submit.
```

### Step 5: Telemetry

```bash
bash bin/telemetry.sh emit "command" '{"command":"contribute","subcommand":"start"}' 2>/dev/null &
```

The user now works on their changes. Claude assists normally. When ready, they run `/contribute submit`.

---

## Submit mode (`/contribute submit`)

### Step 6: Validate state

```bash
CURRENT_BRANCH=$(git branch --show-current)
```

**If not on a `contribute/*` branch**: Check for framework changes vs upstream:

```bash
FRAMEWORK_CHANGES=$(git diff upstream/main --name-only -- bin/ .claude/commands/ .claude/agents/ loom/ CLAUDE.md skills/ 2>/dev/null)
```

- If changes exist on a non-contribute branch: offer to cherry-pick into a contribution branch
- If no changes: "No framework changes found. Make changes first, then `/contribute submit`." Stop.

**If on a `contribute/*` branch**: Proceed.

### Step 7: Show changes for review

```bash
DIFF_STAT=$(git diff upstream/main --stat -- bin/ .claude/commands/ .claude/agents/ loom/ CLAUDE.md skills/)
DIFF_FILES=$(git diff upstream/main --name-only -- bin/ .claude/commands/ .claude/agents/ loom/ CLAUDE.md skills/)
```

Show the diff. Also warn about out-of-scope changes:

```bash
NON_FRAMEWORK=$(git diff upstream/main --name-only | grep -v '^bin/' | grep -v '^\.claude/commands/' | grep -v '^\.claude/agents/' | grep -v '^loom/' | grep -v '^CLAUDE\.md$' | grep -v '^skills/' | head -5)
```

If non-empty:
> These files are outside framework scope and won't be included:
> {list}

### Step 8: Stage framework files only

```bash
git add bin/ .claude/commands/ .claude/agents/ loom/ CLAUDE.md skills/ 2>/dev/null
```

If nothing staged: "No framework changes to submit." Stop.

Commit message — use AskUserQuestion:

```
header: "Message"
question: "Describe your contribution:"
options:
  - label: "{auto-derived from diff — e.g. 'fix: improve /save error handling'}"
    description: "Based on your changes"
  - label: "I'll write my own"
    description: "Enter a custom message"
```

```bash
git commit -m "$COMMIT_MESSAGE"
```

### Step 9: Safety scan

Check for org-specific content that shouldn't go upstream:

```bash
ORG_NAME=$(jq -r '.org_name // empty' egregore.json 2>/dev/null)
GITHUB_ORG=$(jq -r '.github_org // empty' egregore.json 2>/dev/null)
SLUG=$(jq -r '.slug // empty' egregore.json 2>/dev/null)

LEAKS=""
for f in $DIFF_FILES; do
  FOUND=$(grep -n "$ORG_NAME\|$GITHUB_ORG\|$SLUG" "$f" 2>/dev/null)
  [ -n "$FOUND" ] && LEAKS="${LEAKS}\n${f}:\n${FOUND}"
done
```

If leaks found, use AskUserQuestion:

```
header: "Safety"
question: "Your changes contain org-specific references. Clean up before submitting?"
options:
  - label: "Fix first"
    description: "I'll clean these up"
  - label: "It's fine"
    description: "False positives or intentional"
```

If "Fix first" → Stop.

### Step 10: Push to fork

```bash
git push contribute "$CONTRIBUTE_BRANCH" -u --quiet 2>&1
```

If push fails: "Push failed. Your changes are saved locally. Check your network and try `/contribute submit` again." Stop.

### Step 11: Create cross-fork PR

```bash
PR_URL=$(gh pr create \
  --repo "$UPSTREAM_REPO" \
  --head "${GH_USER}:${CONTRIBUTE_BRANCH}" \
  --base main \
  --title "$COMMIT_MESSAGE" \
  --body "$(cat <<EOF
$DESCRIPTION

### Changes
$(git diff upstream/main --stat -- bin/ .claude/commands/ .claude/agents/ loom/ CLAUDE.md skills/)

---
Contributed via \`/contribute\` from an Egregore instance.
EOF
)" 2>&1)
```

If PR creation fails: "PR creation failed, but your branch is pushed to your fork. Create the PR manually at github.com/{GH_USER}/{repo_name}." Stop.

Extract PR number from URL.

### Step 12: Confirmation

```
┌──────────────────────────────────────────────────────────────────────┐
│  ↑ CONTRIBUTED                                  {author} · {date}   │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  {PR title}                                                          │
│  → {UPSTREAM_REPO} · PR #{number}                                    │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  ✓ Pushed to fork · PR created                                      │
│  {PR URL}                                                            │
└──────────────────────────────────────────────────────────────────────┘
```

### Step 13: Return to working branch

```bash
git checkout "$PREVIOUS_BRANCH" 2>/dev/null || git checkout develop 2>/dev/null || true
```

### Step 14: Telemetry

```bash
bash bin/telemetry.sh emit "command" '{"command":"contribute","subcommand":"submit"}' 2>/dev/null &
```

---

## Status mode (`/contribute status`)

```bash
CONTRIBUTE_BRANCHES=$(git branch --list "contribute/*" --format="%(refname:short)")
```

For each branch, check:
- Diff stat vs upstream/main
- Whether pushed to fork (`git log contribute/$branch --oneline -1 2>/dev/null`)
- Whether PR exists (`gh pr list --repo "$UPSTREAM_REPO" --head "${GH_USER}:${branch}" --json number,state --jq '.[0]' 2>/dev/null`)

Display:

```
↑ Contributions to {UPSTREAM_REPO}

  contribute/improve-save-command
    +42/-8, 3 files · pushed · PR #17 (open)

  contribute/fix-graph-sync
    +8/-2, 1 file · local only · no PR

  /contribute submit to push the current branch.
```

If no contribute branches: "No contributions in progress. Run `/contribute` to start one."

---

## Edge cases

| Scenario | Handling |
|----------|----------|
| `upstream_url` is `"none"` | Gate: redirect to `/save` |
| `upstream_url` is empty | Default to `egregore-labs/egregore` |
| Fork already exists | `gh repo fork` is idempotent |
| `contribute` remote exists | Skip adding |
| No framework changes | "Make changes first, then `/contribute submit`" |
| Org-specific refs in changes | Safety scan warns |
| Already on `contribute/*` branch | Offer to submit or start new |
| PR exists for this branch | Show existing PR URL, don't create duplicate |
| Push fails | Preserve local changes, suggest retry |
| PR creation fails | Branch is pushed, suggest manual PR |
