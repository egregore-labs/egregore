---
name: update
description: "Update local Egregore environment — sync the framework from upstream, run post-update migrations, and pull repos. Use for /update or when framework behavior seems broken or missing."
---

Update local Egregore environment — sync framework from upstream and pull repos.

## When to invoke

User says: "/update", "update Egregore", "sync the framework", "get the latest framework" — or framework behavior seems broken or missing (the first thing to try).
Not this: syncing managed repos + memory only, no framework sync → `/pull`

## What to do

1. **Sync framework from upstream** (egregore-labs/egregore)
2. **Run post-update migrations** (`bin/post-update.sh`)
3. **Run `/pull`** (sync base branch + memory)
4. Show what changed

## Step 1: Detect environment

Detect the base branch and whether we're in a worktree. Framework updates MUST land on the base branch, never on working branches.

```bash
bash bin/base-branch.sh
```

Use the printed branch name as `{base}`; quote placeholders in single quotes when you use them in a command, and write any single quote inside a value as `'\''`. A non-zero exit means the configuration could not be resolved: stop before any Git change.

```bash
git branch --show-current
```

Use the printed branch as `{current_branch}` for the non-worktree switch and restore steps.

```bash
# Detect worktree: .git is a file (not a directory) in worktrees
test -f .git
```

Use `true` as `{in_worktree}` if the test exits successfully; otherwise use `false`. If `{in_worktree}` is `true`, locate the main checkout:

```bash
git rev-parse --path-format=absolute --git-common-dir
```

Use the printed common Git directory's parent as `{main_dir}`, the main checkout.

## Step 2: Sync framework to base branch

Egregore is a framework — updates come from upstream, not from your own repo's history.

**Freeze lever — check FIRST, before touching any remote:**

```bash
bash bin/config-get.sh upstream_url
```

Use the printed value as `{upstream_url}`. If it prints `none`, this instance **does not pull framework from
upstream** — it is either the framework source of truth (framework changes are
authored here and flow OUT via `/sync-public`) or deliberately frozen. **Skip
Step 2 entirely** — do NOT add an upstream remote, do NOT checkout any path.
Tell the user: `⛔ upstream_url is "none" — this instance never pulls framework
from upstream. Skipping framework sync; running migrations + /pull only.` Then
continue with Step 3. A wholesale upstream checkout on a source-of-truth
instance reverts downstream work (the 578deee incident: 23 files, −1131 lines).

**In a worktree:** The base branch is checked out in the main repo. Use `git -C` to update it there — `git checkout '{base}'` would fail since git won't let two worktrees share a branch.

**Not in a worktree:** Switch to the base branch directly.

Use `{upstream_url}` as `{upstream}` when set; if the command prints nothing, use
`https://github.com/egregore-labs/egregore.git` as `{upstream}`.

If `{in_worktree}` is `true`, ensure the upstream remote exists in the main checkout:

```bash
git -C '{main_dir}' remote add upstream '{upstream}'
```

If it reports that the remote already exists, run `git -C '{main_dir}' remote set-url upstream '{upstream}'` instead.

```bash
git -C '{main_dir}' fetch upstream main --quiet
```

If `{in_worktree}` is `false`, ensure the upstream remote exists in this checkout:

```bash
git remote add upstream '{upstream}'
```

If it reports that the remote already exists, run `git remote set-url upstream '{upstream}'` instead.

```bash
git fetch upstream main --quiet
```

### Worktree path

If `{in_worktree}` is `true`, sync framework paths only in the named main checkout:

```bash
bash bin/update-framework.sh --main-dir '{main_dir}'
```

Stop if the command fails: the target checkout, upstream remote, and fetched
`upstream/main` must exist. Individual missing or failed paths are tolerated and
reported once. This path checkout is unaffected by the user's merge or rebase
settings; it never switches branches or discovers another worktree.

```bash
if [ '{in_worktree}' = "true" ]; then
  # Regenerate AGENTS.md. It is GENERATED from CLAUDE.md by
  # bin/codex-render-spec.mjs and is deliberately NOT in the overlay above —
  # so without this step downstream workspaces never receive AGENTS.md framework
  # changes (e.g. the Claude-Code runtime-precedence guard). Regenerate from the
  # freshly-synced CLAUDE.md + script; fall back to the prebuilt upstream copy if
  # node is unavailable or the render fails.
  if command -v node >/dev/null 2>&1 && [ -f '{main_dir}/bin/codex-render-spec.mjs' ]; then
    node '{main_dir}/bin/codex-render-spec.mjs' 2>/dev/null \
      || git -C '{main_dir}' checkout upstream/main -- AGENTS.md .codex/spec-manifest.json 2>/dev/null || true
    [ -f '{main_dir}/bin/pi-render-spec.mjs' ] && node '{main_dir}/bin/pi-render-spec.mjs' 2>/dev/null || true
    [ -f '{main_dir}/bin/prime-render-spec.mjs' ] && node '{main_dir}/bin/prime-render-spec.mjs' 2>/dev/null || true
  else
    git -C '{main_dir}' checkout upstream/main -- AGENTS.md .codex/spec-manifest.json 2>/dev/null || true
  fi

  # Regenerate Codex adapter skills from the freshly-synced Claude skills.
  # Generated adapters carry a marker; hand-written natives are never touched.
  # Without this, adapters for changed skills go stale until the next manual run.
  [ -f '{main_dir}/bin/codex-sync-skills.sh' ] && (cd '{main_dir}' && bash bin/codex-sync-skills.sh) >/dev/null 2>&1 || true

  # Restore org-owned skills (egregore.json → owned_skills[]) before committing.
  # On a name collision the org's committed version wins; the script reports it.
  (cd '{main_dir}' && bash bin/restore-owned-skills.sh) || true
fi
```

If `{in_worktree}` is `true`, review the changes and continue the worktree update:

```bash
if [ '{in_worktree}' = "true" ]; then
  # Show what changed
  git -C '{main_dir}' diff --stat HEAD

  # Commit on base branch in main repo (.codex/skills/ carries the
  # regenerated adapters)
  git -C '{main_dir}' add -A .claude/ .pi/ .prime/ bin/ loom/ CLAUDE.md skills/ AGENTS.md .codex/spec-manifest.json .codex/skills/ 2>/dev/null
  if ! git -C '{main_dir}' diff --cached --quiet 2>/dev/null; then
    EGREGORE_FRAMEWORK_UPDATE=1 git -C '{main_dir}' commit -m "Update Egregore framework from upstream"
    git -C '{main_dir}' push origin '{base}' --quiet 2>/dev/null || true
  fi

  # Rebase worktree branch onto updated base
  git stash --quiet 2>/dev/null || true
  git fetch origin '{base}' --quiet
  if ! git rebase 'origin/{base}' --quiet 2>/dev/null; then
    git rebase --abort 2>/dev/null || true
    echo '⚠ Rebase had conflicts — aborted. Run: git rebase origin/{base} and resolve manually.'
  fi
  git stash pop --quiet 2>/dev/null || true
fi
```

### Non-worktree path

If `{in_worktree}` is `false`, use `false` as `{switched}` initially.

Still only when `{in_worktree}` is `false`, if `{current_branch}` differs from
`{base}`, stash the work and switch to the base branch, recording the switch
for Step 4. If they match, keep the current branch and leave `{switched}` as `false`.

```bash
git stash --quiet 2>/dev/null || true
git checkout '{base}' --quiet 2>/dev/null
```

After switching successfully, use `true` as `{switched}` for Step 4.

If `{in_worktree}` is `false`, sync the same framework paths in this checkout:

```bash
bash bin/update-framework.sh
```

Stop on failure as in the worktree path, then continue the non-worktree path:

```bash
if [ '{in_worktree}' = "false" ]; then
  # Regenerate AGENTS.md from the freshly-synced CLAUDE.md (it is generated by
  # bin/codex-render-spec.mjs and not in the overlay above). Fall back to the
  # prebuilt upstream copy if node is unavailable or the render fails.
  if [ -f bin/node-run.sh ] && [ -f bin/codex-render-spec.mjs ]; then
    bash bin/node-run.sh bin/codex-render-spec.mjs 2>/dev/null \
      || git checkout upstream/main -- AGENTS.md .codex/spec-manifest.json 2>/dev/null || true
    [ -f bin/pi-render-spec.mjs ] && bash bin/node-run.sh bin/pi-render-spec.mjs 2>/dev/null || true
    [ -f bin/prime-render-spec.mjs ] && bash bin/node-run.sh bin/prime-render-spec.mjs 2>/dev/null || true
  else
    git checkout upstream/main -- AGENTS.md .codex/spec-manifest.json 2>/dev/null || true
  fi

  # Regenerate Codex adapter skills from the freshly-synced Claude skills
  # (generated adapters carry a marker; hand-written natives are never touched).
  [ -f bin/codex-sync-skills.sh ] && bash bin/codex-sync-skills.sh >/dev/null 2>&1 || true

  # Restore org-owned skills (egregore.json → owned_skills[]) before committing.
  # On a name collision the org's committed version wins; the script reports it.
  bash bin/restore-owned-skills.sh || true
fi
```

If `{in_worktree}` is `false`, show the changes before continuing:

```bash
if [ '{in_worktree}' = "false" ]; then
  # Show what changed
  git diff --stat HEAD
fi
```

**Framework paths synced:** `bin/`, `.claude/commands/`, `.claude/skills/`, `.claude/hooks/`, `.claude/context/`, `.claude/agents/`, `.pi/`, `.prime/`, `loom/`, `CLAUDE.md`, `skills/`
**Regenerated:** `AGENTS.md` + `.codex/spec-manifest.json` via `bin/codex-render-spec.mjs`, `.pi/APPEND_SYSTEM.md` + `.pi/spec-manifest.json` via `bin/pi-render-spec.mjs`, `.prime/agent/APPEND_SYSTEM.md` + `.prime/agent/spec-manifest.json` via `bin/prime-render-spec.mjs`, then generated Codex adapter skills via `bin/codex-sync-skills.sh`, so all derived harnesses stay aligned with `CLAUDE.md` and the canonical skills.
**Never touched:** `egregore.json`, `.env`, `memory/`, `.egregore-state.json`, `.mcp.json`
**Org-owned skills:** names in `egregore.json` → `owned_skills[]` are restored from the org's committed state after the overlay (`bin/restore-owned-skills.sh`) — upstream never overwrites them; collisions are reported instead.

## Step 3: Post-update migrations

After syncing, run `bin/post-update.sh` if it exists. In worktrees, run from `{main_dir}` to ensure the updated version executes even if the rebase didn't complete.

```bash
if [ '{in_worktree}' = "true" ]; then
  [ -x '{main_dir}/bin/post-update.sh' ] && bash '{main_dir}/bin/post-update.sh'
else
  [ -x bin/post-update.sh ] && bash bin/post-update.sh
fi
```

## Step 4: Commit and switch back (non-worktree only)

Worktree path already committed in Step 2. This handles the non-worktree case:

```bash
if [ '{in_worktree}' = "false" ]; then
  git add -A .claude/ .pi/ .prime/ bin/ loom/ CLAUDE.md skills/ AGENTS.md .codex/spec-manifest.json 2>/dev/null
  if ! git diff --cached --quiet 2>/dev/null; then
    EGREGORE_FRAMEWORK_UPDATE=1 git commit -m "Update Egregore framework from upstream"
    git push origin '{base}' --quiet 2>/dev/null || true
  fi

  # Switch back to working branch, rebase, restore user's work
  if [ '{switched}' = "true" ]; then
    git checkout '{current_branch}' --quiet 2>/dev/null
    if ! git rebase '{base}' --quiet 2>/dev/null; then
      git rebase --abort 2>/dev/null || true
      echo '⚠ Rebase had conflicts — aborted. Run: git rebase {base} and resolve manually.'
    fi
    git stash pop --quiet 2>/dev/null || true
  fi
fi
```

The `EGREGORE_FRAMEWORK_UPDATE=1` marker tells the branch guard this is safe on the base branch.

## Step 5: Pull repos

Run `/pull` logic (sync base branch, rebase working branch, pull memory).

## Example (on main, no worktree)

```
> /update

Syncing framework from upstream...
  bin/activity-data.sh         | 89 +++++------
  .claude/skills/handoff/      | new
  bin/post-update.sh           | 12 +++---
  3 files changed, 32 insertions(+), 22 deletions(-)

Running post-update migrations...
  ✓ Removed .claude/commands/ (migrated to skills)

  ✓ Framework updated and committed to main

Pulling...
  main           ✓ synced
  memory         ✓ up to date
```

## Example (on working branch in worktree)

```
> /update

Syncing framework in main repo (on develop)...
  bin/notify.sh                | 12 +++---
  .claude/skills/update/       | modified
  2 files changed, 18 insertions(+), 6 deletions(-)

  ✓ Framework updated and committed to develop
  ✓ Rebased working branch onto develop

Pulling...
  develop        ✓ synced
  memory         ✓ up to date
```

## If framework is already current

```
Syncing framework from upstream...
  ✓ Already up to date
```
