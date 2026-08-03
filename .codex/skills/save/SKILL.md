---
name: save
description: Save Egregore work when the user invokes /save or $save, or asks to commit, push, sync, or save current changes from a Codex Egregore session.
---

# Egregore Save

Native Codex Egregore skill. This is the user-facing abstraction for the git
and memory workflow: users should be able to say "save this" without knowing
which branch, commit, push, pull request, or memory sync steps are required.

## Flow

1. Confirm this is an Egregore checkout by checking for `bin/agent.sh`.
2. Inspect state silently:

```bash
BASE=$(bash -c 'SCRIPT_DIR="$PWD"; CONFIG="$PWD/egregore.json"; . "$PWD/bin/lib/config.sh" && _get_base_branch') ||
  { echo "Could not resolve the configured base branch; stopping before Git changes." >&2; exit 1; }
git status --short
git status --short memory 2>/dev/null || true
BRANCH=$(git branch --show-current)
AHEAD=0
OPEN_PR=""
case "$BRANCH" in
  dev/*|feature/*|bugfix/*)
    git fetch origin "$BASE" --quiet 2>/dev/null || true
    AHEAD=$(git rev-list --count "origin/$BASE..HEAD" 2>/dev/null || echo 0)
    if command -v gh >/dev/null 2>&1; then
      OPEN_PR=$(gh pr list --head "$BRANCH" --base "$BASE" --state open \
        --json url --jq '.[0].url // empty' 2>/dev/null || true)
    fi
    ;;
esac
```

3. A clean working tree alone does **not** mean the work is fully saved:
   - If there are repo or memory changes, continue.
   - If the task branch is ahead of `origin/$BASE` and `OPEN_PR` is empty,
     continue even when the tree is clean. The bridge must push any committed
     work and create the missing PR.
   - Stop with "everything is already saved" only when there are no repo or
     memory changes and either the branch has no commits to integrate
     (`AHEAD=0`) or an open integration PR already exists.
4. Run the product distribution checkpoint before any commit or push when
   `capability-distribution.json` exists:

```bash
node bin/capability-distribution.mjs validate --root .
node bin/capability-distribution.mjs changes --root . --base "origin/$BASE" --json
```

   Inspect the diff as well as the receipt. Ask when this work introduces a new
   or unclassified Egregore component, or changes a component's placement
   without an explicit user decision in the current conversation. Components
   include skills, packages, APIs, sites, workers, infrastructure, schemas,
   assets, and runtime tools. Ordinary edits to an already classified component
   do not prompt.

   Show the tracker before asking:

   `artifacts/capability-pipeline.html`

   Ask once using structured Codex question tooling when available. Otherwise
   render the compact numbered question and wait:

```text
Where should {name} live?
1. OSS + Connect — part of the open runtime; Connect inherits it
2. Connect only — delivered only to authenticated Connect users
3. Curve Labs / Egregore — used only in this development instance
```

   Record every new component as `queued` under the selected placement and
   attach all of its governed source paths. Availability is changed separately
   after review. Group components into one checkpoint only when they share the
   same placement. Apply the answer to `capability-distribution.json`, regenerate
   `skill-distribution.json` and both artifacts, then validate again. Rebuild
   runtime packs when an available runtime component changes placement. If the
   user already made this exact decision during the current work, do not ask
   twice.
5. Synthesize:
   - a short topic from the work,
   - a clear commit message,
   - a one-line user-facing scope summary,
   - a PR description following `.claude/context/pr-format.md`:
     `## What` (1–4 bullets), `## Why` (1–3 sentences), and
     `## Verification` (how the change was checked — required when the
     diff touches non-markdown files; be honest if unverified).
6. If the scope is ambiguous or includes unrelated changes, ask for one compact
   confirmation. Use structured Codex question tooling when available;
   otherwise render:

```text
Save these changes?
1. Save all
2. Narrow scope
Other:
```

7. Run the bridge command:

```bash
bin/agent.sh save --message "$MESSAGE" --topic "$TOPIC" --pr-body "$PR_BODY"
```

The bridge owns the mechanical workflow: sync memory, ensure a task branch,
commit repo changes, push, and create or reuse a pull request when available.
Always pass the synthesized `--pr-body` — the bridge only auto-generates a
skeleton body as a last resort, and the CI `pr-format` check gates every PR.

8. Parse the output and report only useful user information:
   - branch name,
   - whether a commit was created,
   - whether push succeeded,
   - pull request URL if present,
   - memory sync status.

## Rules

- Do not ask the user to run git commands.
- Do not expose implementation detail unless save fails.
- If save fails, say which step failed and leave the branch/path clear.
- Never run destructive git commands.
- Do not use Claude Code commands.
