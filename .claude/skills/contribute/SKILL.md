---
name: contribute
description: "Contribute an improvement back to the upstream Egregore framework as a cross-fork pull request. Use for /contribute, or submitting a framework fix upstream — not saving org work (/save) or filing a bug (/issue)."
---

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

Resolve the contribution target through the shared executable guard. This is
mandatory for every mode, including `status`, and replaces any hand-written
interpretation of `upstream_url`:

```bash
bash bin/contribute-guard.sh
```

Use the printed target as `{upstream_repo}`; quote placeholders in single quotes when you use them in a command, and write any single quote inside a value as `'\''`.

If the guard refuses because `upstream_url` is `"none"`, tell the user:

> This is the framework source repository. Use `/save` to push changes to its configured integration branch.

Stop.

For malformed configuration, unsupported URLs, or any other guard failure,
show its error and stop. Never substitute a public target after a guard error.

## Step 1: Check auth + get username

```bash
gh api user --jq '.login' 2>/dev/null
```

Use the printed login as `{gh_user}`.

If empty: "Run `bash bin/github-auth.sh` first — you need GitHub access to contribute." Stop.

---

## Interactive mode (default / topic provided)

### Step 2: Understand intent

If `$ARGUMENTS` is non-empty (and not `submit`/`status`), use as the topic description.

If empty, ask with a structured question when available and permitted in this session; otherwise ask in plain text:

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

Run all three steps in order:

```bash
# Revalidate immediately before the first external mutation. A target change
# or source-repository config stops the entire command block.
bash bin/contribute-guard.sh --expect '{upstream_repo}' >/dev/null || exit $?

# 3a: Fork upstream (idempotent — no-ops if fork exists)
gh repo fork '{upstream_repo}' --clone=false 2>/dev/null || true
```

Check whether the contribute remote exists:

```bash
# 3b: Add contribute remote (skip if exists)
git remote get-url contribute &>/dev/null
```

If the check exits nonzero, add the remote; if it succeeds, skip adding it:

Use the part after `/` in `{upstream_repo}` as `{repo_name}`.

```bash
git remote add contribute 'https://github.com/{gh_user}/{repo_name}.git' 2>/dev/null
```

Then fetch the remote and continue with branch setup:

```bash
git fetch contribute --quiet 2>/dev/null || true

# 3c: Create contribution branch from upstream/main
git fetch upstream main --quiet 2>/dev/null || true
```

Derive topic slug: lowercase the description, replace every character outside `a-z0-9` with `-`, collapse consecutive hyphens, remove leading and trailing hyphens, then keep the first 40 characters as `{topic_slug}`. Use `contribute/{topic_slug}` as `{contribute_branch}`.

Save current branch for later return:
```bash
git branch --show-current
```

Keep the printed value as `{previous_branch}` for the return in Step 13.

Check if branch exists:
```bash
if git show-ref --verify --quiet 'refs/heads/{contribute_branch}' 2>/dev/null; then
  # Branch exists — ask: resume or start fresh?
fi
```

If new:
```bash
git checkout -b '{contribute_branch}' upstream/main --quiet
```

### Step 4: Confirm setup

```
Contributing to {upstream_repo}

  Fork:   github.com/{gh_user}/{repo_name}
  Branch: {contribute_branch}
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
git branch --show-current
```

Use the printed value as `{branch}` for the branch checks below.

**If not on a `contribute/*` branch**: Check for framework changes vs upstream:

```bash
git diff upstream/main --name-only -- bin/ .claude/commands/ .claude/agents/ loom/ CLAUDE.md skills/ 2>/dev/null
```

Use the printed file list as `{framework_changes}`.

- If changes exist on a non-contribute branch: offer to cherry-pick into a contribution branch
- If no changes: "No framework changes found. Make changes first, then `/contribute submit`." Stop.

**If on a `contribute/*` branch**: Use `{branch}` as `{contribute_branch}` and proceed.

### Step 7: Show changes for review

```bash
git diff upstream/main --stat -- bin/ .claude/commands/ .claude/agents/ loom/ CLAUDE.md skills/
git diff upstream/main --name-only -- bin/ .claude/commands/ .claude/agents/ loom/ CLAUDE.md skills/
```

Use the first command's output as `{diff_stat}` and the second command's file list as `{diff_files}`.

Show the diff. Also warn about out-of-scope changes:

```bash
git diff upstream/main --name-only | grep -v '^bin/' | grep -v '^\.claude/commands/' | grep -v '^\.claude/agents/' | grep -v '^loom/' | grep -v '^CLAUDE\.md$' | grep -v '^skills/' | head -5
```

Use the printed file list as `{non_framework}`.

If non-empty:
> These files are outside framework scope and won't be included:
> {list}

### Step 8: Stage framework files only

```bash
git add bin/ .claude/commands/ .claude/agents/ loom/ CLAUDE.md skills/ 2>/dev/null
```

If nothing staged: "No framework changes to submit." Stop.

Commit message — per `.claude/context/commit-format.md`; ask with a structured question when available and permitted in this session; otherwise ask in plain text:

```
header: "Message"
question: "Describe your contribution:"
options:
  - label: "{auto-derived from diff — e.g. 'fix(save): improve error handling'}"
    description: "Based on your changes"
  - label: "I'll write my own"
    description: "Enter a custom message"
```

Use `{commit_message}` for the commit message chosen in the preceding question, escaping embedded single quotes as `'\''`:

```bash
git commit -m '{commit_message}'
```

### Step 9: Safety scan

Check for org-specific content that shouldn't go upstream:

Use `{diff_files}` from Step 7 as separate file arguments, each single-quoted;
write any single quote inside a path as `'\''`:

```bash
bash bin/contribute-guard.sh scan -- {diff_files}
```

For a long list, write those paths, one per line, to
`tmp/contribute-files.txt`, then run this instead:

```bash
bash bin/contribute-guard.sh scan --stdin < tmp/contribute-files.txt
```

The guard reads `org_name`, `github_org`, and `slug` from configuration and prints
`path:line:match` rows. Exit 1 means references matched, 0 means clean (including
an empty list); deleted files are skipped. On exit 2, show the error and stop.

If leaks found, ask with a structured question when available and permitted in this session; otherwise ask in plain text:

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
bash bin/contribute-guard.sh --expect '{upstream_repo}' >/dev/null || exit $?
git push contribute '{contribute_branch}' -u --quiet 2>&1
```

If push fails: "Push failed. Your changes are saved locally. Check your network and try `/contribute submit` again." Stop.

### Step 11: Create cross-fork PR

Refresh the diff stat for the PR body:

```bash
git diff upstream/main --stat -- bin/ .claude/commands/ .claude/agents/ loom/ CLAUDE.md skills/
```

Use the printed value as `{diff_stat}`. Write `tmp/pr-body.md` following `.claude/context/pr-format.md`, including the contribution description from the user's arguments or Step 2 answer, `{diff_stat}`, and the credit "Contributed via `/contribute` from an Egregore instance."

Revalidate `{upstream_repo}`, the target printed by the guard, and stop if it refuses:
```bash
bash bin/contribute-guard.sh --expect '{upstream_repo}' >/dev/null
```

Use `{commit_message}` from Step 8 as the title, `{upstream_repo}` from the guard, `{gh_user}` from the authenticated login, and `{contribute_branch}` from the current contribution branch:
```bash
gh pr create \
  --repo '{upstream_repo}' \
  --head '{gh_user}:{contribute_branch}' \
  --base main \
  --title '{commit_message}' \
  --body-file tmp/pr-body.md 2>&1
```

Use the printed URL as `{pr_url}` for the confirmation below.

If PR creation fails: "PR creation failed, but your branch is pushed to your fork. Create the PR manually at github.com/{gh_user}/{repo_name}." Stop.

Extract PR number from `{pr_url}`.

### Step 12: Confirmation

```
┌──────────────────────────────────────────────────────────────────────┐
│  ↑ CONTRIBUTED                                  {author} · {date}   │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  {PR title}                                                          │
│  → {upstream_repo} · PR #{number}                                    │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  ✓ Pushed to fork · PR created                                      │
│  {pr_url}                                                            │
└──────────────────────────────────────────────────────────────────────┘
```

### Step 13: Return to working branch

```bash
git checkout '{previous_branch}'
```

If it fails, run:

```bash
git checkout develop
```

### Step 14: Telemetry

```bash
bash bin/telemetry.sh emit "command" '{"command":"contribute","subcommand":"submit"}' 2>/dev/null &
```

---

## Status mode (`/contribute status`)

```bash
git branch --list "contribute/*" --format="%(refname:short)"
```

Use the printed branch list as `{contribute_branches}`.

For each branch, check:
- Diff stat vs upstream/main
- Whether pushed to fork (`git log contribute/$branch --oneline -1 2>/dev/null`)
- Whether PR exists (`gh pr list --repo '{upstream_repo}' --head '{gh_user}:{branch}' --json number,state --jq '.[0]' 2>/dev/null`)

Display:

```
↑ Contributions to {upstream_repo}

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
| `upstream_url` is `"none"` | Executable guard refuses all contribution operations and redirects to `/save` |
| `upstream_url` is empty | Executable guard selects `egregore-labs/egregore` |
| Config is invalid or target changes | Executable guard fails closed before fork, push, or PR |
| Fork already exists | `gh repo fork` is idempotent |
| `contribute` remote exists | Skip adding |
| No framework changes | "Make changes first, then `/contribute submit`" |
| Org-specific refs in changes | Safety scan warns |
| Already on `contribute/*` branch | Offer to submit or start new |
| PR exists for this branch | Show existing PR URL, don't create duplicate |
| Push fails | Preserve local changes, suggest retry |
| PR creation fails | Branch is pushed, suggest manual PR |
