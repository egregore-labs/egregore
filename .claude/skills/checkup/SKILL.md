---
name: checkup
description: "Run diagnostics on your Egregore environment and render a health report, auto-fixing what it can. Use for /checkup, a health check, or when something is broken and the root cause is unclear."
---

Run diagnostics on your Egregore environment.

Check every service and dependency, render a TUI diagnostic box, and auto-fix what you can.

## When to invoke

- User says "checkup", "diagnose", "what's broken", "health check", "status check"
- Session greeting shows `⚠ Issues detected — run /checkup`
- User reports something not working and root cause is unclear

## Procedure

**First, detect mode.** This gates which checks run.

```bash
MODE=$(jq -r '.mode // empty' egregore.json 2>/dev/null)
API_URL=$(jq -r '.api_url // empty' egregore.json 2>/dev/null)
if [ "$MODE" = "local" ] || [ -z "$API_URL" ]; then
  MODE="local"
else
  MODE="connected"
fi
```

In **local mode**, Checks 3b, 4, 5, 6 are skipped entirely (no graph, no API key, no telegram). The SERVICES section of the diagnostic box is not rendered.

In **connected mode**, all checks run as below.

Run checks in **3 sequential batches**. Within each batch, checks can run in parallel. **Never run network checks (5-6) in the same parallel batch as local checks (7-10)** — a network timeout will cascade-cancel the siblings.

**Batch 1** (local, fast): Checks 1-2, GitHub token.
**Batch 2** (network, may timeout, connected mode only): Checks 3b, 4, 5-6 — identity (Person node), API key, graph, telegram
**Batch 3** (local + git): Checks 7-10 — memory, git, framework, alias

Collect results into a `checks` array, then render the diagnostic box.

### Check 1: Config (egregore.json)

```bash
jq . egregore.json
```

- **Pass (connected mode)** if valid JSON with non-empty `org_name`, `github_org`, `slug`, `api_url`
- **Pass (local mode)** if valid JSON with non-empty `org_name`, `github_org`, `slug` — `api_url` is not required
- **Fail** if file missing, invalid JSON, or required fields empty
- **Fix**: run `/setup`

Extract `slug` and `org_name` for display.

### Check 2: Environment (.env)

```bash
test -f .env && grep -c '^[A-Z]' .env
```

- **Pass (connected mode)** if `.env` exists and has both `GITHUB_TOKEN` and `EGREGORE_API_KEY`
- **Pass (local mode)** if `.env` exists and has `GITHUB_TOKEN` — `EGREGORE_API_KEY` is not required
- **Fail** if missing file or missing keys
- **Fix**: for missing `GITHUB_TOKEN`, run `bash bin/github-auth.sh`. In connected mode, a missing `EGREGORE_API_KEY` is auto-fetched via Check 4's fix below.

Count the keys present for display.

### Check 3: GitHub token

```bash
TOKEN=$(grep '^GITHUB_TOKEN=' .env | cut -d'=' -f2-)
curl -s -H "Authorization: token $TOKEN" https://api.github.com/user --max-time 5
```

- **Pass** if response has `.login`
- **Fail** if 401, timeout, or no login
- **Fix**: run `bash bin/github-auth.sh`

Show `authenticated as {login}` on pass.

### Check 3b: Identity (Person node) — connected mode only

**In local mode, skip this check entirely. Do not run the bash block below.** There is no graph.

```bash
if [ "$MODE" = "connected" ]; then
  AUTHOR=$(jq -r '.github_username // empty' .egregore-state.json 2>/dev/null)
  DISPLAY_NAME=$(jq -r '.display_name // empty' .egregore-state.json 2>/dev/null)
  RESULT=$(bash bin/graph.sh query "MATCH (p:Person {github: \$gh}) RETURN p.name AS name, p.github AS github" "{\"gh\":\"$AUTHOR\"}" 2>/dev/null)
fi
```

- **Pass** if Person node exists and `p.name` matches local `display_name` (or `github_username` if no display_name set)
- **Warn** if Person node exists but `p.name` doesn't match local `display_name` (drift between local state and graph)
- **Fail** if no Person node found for this github username
- **Fix** for warn: run `/me {display_name}` to re-sync. For fail: next session start will create it automatically.

Show `known as {p.name} ({p.github})` on pass, `drift: local={display_name}, graph={p.name}` on warn.

### Check 4: API key — connected mode only

**In local mode, skip this check entirely. Do not run the bash block below.** There is no API key.

The test is whether the API **accepts** the key — not whether its slug prefix matches `egregore.json`. After an org rename, the old-slug key can be the only key bound to the org's data, and the new-slug key may authenticate against an empty namespace. **Never replace a key that authenticates just because its slug differs from the config.**

```bash
if [ "$MODE" = "connected" ]; then
  CURRENT_KEY=$(grep '^EGREGORE_API_KEY=' .env | cut -d'=' -f2-)
  KEY_SLUG=$(echo "$CURRENT_KEY" | cut -d'_' -f2)
  PROBE_CODE=$(curl -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $CURRENT_KEY" \
    "${API_URL}/api/graph/test" --max-time 10)
fi
```

- **Pass** if `PROBE_CODE` is 200 (key authenticates)
- **Fail** if key missing, or `PROBE_CODE` is 401/403 (API rejects it)
- **Warn** if any other code (API unreachable — can't validate; do NOT touch the key)
- **Fix** (fail only): fetch a key for the config slug via API:
  ```bash
  EXPECTED_SLUG=$(jq -r '.slug // empty' egregore.json)
  TOKEN=$(grep '^GITHUB_TOKEN=' .env | cut -d'=' -f2-)
  curl -s -X GET "${API_URL}/api/org/${EXPECTED_SLUG}/key" -H "Authorization: Bearer $TOKEN" --max-time 10
  ```
  Then update `.env` with the returned `api_key`.

Show `valid (authenticates)` on pass — append `legacy slug: {KEY_SLUG}` if the slug differs from the config slug. Show `rejected by API ({PROBE_CODE})` on fail, `API unreachable — not validated` on warn.

### Check 5: Graph (Neo4j) — connected mode only

**In local mode, skip this check entirely. Do not run the bash block below.** There is no graph.

```bash
if [ "$MODE" = "connected" ]; then
  timeout 10 bash bin/graph.sh test 2>&1; echo "EXIT:$?"
fi
```

- **Pass** if output contains "Connected"
- **Fail** if timeout (exit 124), error, or no "Connected"
- **Fix**: report "API or network is down. No action needed from you."

### Check 6: Telegram — connected mode only

**In local mode, skip this check entirely. Do not run the bash block below.** There are no live notifications.

```bash
if [ "$MODE" = "connected" ]; then
  timeout 10 bash bin/notify.sh test 2>&1; echo "EXIT:$?"
fi
```

- **Pass** if `.status` is `ok` (connected) or `configured` (local)
- **Fail** if timeout (exit 124), error, or `.status` is `offline`
- **Fix**: report status. No user action needed — Telegram is optional.

`notify.sh test` returns JSON, not prose — read the `status` field, never a substring of the whole output.

**Important**: Run checks 5 and 6 together in their own batch, separate from all other checks. Append `EXIT:$?` so you always get output even on timeout — this prevents Claude Code from treating it as a tool error.

### Check 7: Memory repo

```bash
test -L memory && test -d memory/.git
git -C memory status --porcelain
```

- **Pass** if symlink exists, is a git repo, and is clean
- **Warn** if dirty (uncommitted changes)
- **Fail** if symlink missing or not a git repo
- **Fix**: run `/setup`

Show `linked and synced` on pass, `dirty — N uncommitted changes` on warn.

### Check 8: Git state

```bash
git show-ref --verify refs/heads/develop
git rev-parse develop
git rev-parse origin/develop
```

- **Pass** if develop exists and matches origin/develop
- **Warn** if develop exists but diverged
- **Fail** if develop doesn't exist
- **Fix**: run `/pull`

### Check 9: Framework version

```bash
FRAMEWORK_VERSION=$(head -20 bin/session-start.sh | grep 'FRAMEWORK_VERSION=' | cut -d'"' -f2)
git fetch upstream main --quiet 2>/dev/null
UPSTREAM_VERSION=$(git show upstream/main:bin/session-start.sh 2>/dev/null | head -20 | grep 'FRAMEWORK_VERSION=' | cut -d'"' -f2)
```

- **Pass** if versions match or upstream unavailable
- **Warn** if upstream is newer
- **Fix**: run `/update`

Show `v{N} (current)` on pass, `v{N} → v{M} available` on warn.

### Check 10: Shell alias

```bash
SHELL_PROFILE=""
case "$SHELL" in
  */zsh)  SHELL_PROFILE="$HOME/.zshrc" ;;
  */bash) SHELL_PROFILE="$HOME/.bash_profile" ;;
  */fish) SHELL_PROFILE="$HOME/.config/fish/config.fish" ;;
esac
grep -l "$(pwd)" "$SHELL_PROFILE" 2>/dev/null
```

- **Pass** if an alias/function pointing to this directory exists in the shell profile
- **Fail** if not found
- **Fix**: run `bash bin/ensure-shell-function.sh`

Show `{alias_name} in {profile}` on pass.

## Rendering

After collecting all results, render a diagnostic box. In **connected mode**, render all four sections (CONFIG, IDENTITY, SERVICES, WORKSPACE). In **local mode**, omit the SERVICES section entirely and omit the `Person` row from IDENTITY (no graph → no Person node check).

**Connected mode format:**

```
┌──────────────────────────────────────────────────────────────────────┐
│  ⊕ CHECKUP                                          {date}         │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  CONFIG                                                              │
│  ✓ egregore.json valid (slug: {slug}, org: {org_name})              │
│  ✓ .env configured ({N} keys present)                               │
│                                                                      │
│  IDENTITY                                                            │
│  ✓ GitHub — authenticated as {login}                                │
│  ✓ Person — known as {name} ({github})                              │
│                                                                      │
│  SERVICES                                                            │
│  ✓ API key — valid (authenticates)                                  │
│  ✓ Graph — connected                                                │
│  ✓ Telegram — connected                                             │
│                                                                      │
│  WORKSPACE                                                           │
│  ✓ Memory — linked and synced                                       │
│  ✓ Git — develop synced                                             │
│  ✓ Framework v{N} (current)                                         │
│  ✓ Shell alias — {name} in {profile}                                │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  {passed} passed · {warnings} warnings · {errors} errors            │
└──────────────────────────────────────────────────────────────────────┘
```

**Local mode format:**

```
┌──────────────────────────────────────────────────────────────────────┐
│  ⊕ CHECKUP                                          {date}         │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  CONFIG                                                              │
│  ✓ egregore.json valid (slug: {slug}, org: {org_name})              │
│  ✓ .env configured (GITHUB_TOKEN present)                           │
│                                                                      │
│  IDENTITY                                                            │
│  ✓ GitHub — authenticated as {login}                                │
│                                                                      │
│  WORKSPACE                                                           │
│  ✓ Memory — linked and synced                                       │
│  ✓ Git — develop synced                                             │
│  ✓ Framework v{N} (current)                                         │
│  ✓ Shell alias — {name} in {profile}                                │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  {passed} passed · {warnings} warnings · {errors} errors            │
└──────────────────────────────────────────────────────────────────────┘
```

Symbols:
- `✓` = passed
- `⚠` = warning (works but degraded)
- `✗` = failed

For failures, add a `→` line immediately after showing what Claude will do:

```
│  ✗ GitHub — token expired                                           │
│    → Re-authenticating with GitHub...                                │
```

## Auto-fix

After rendering the box, **automatically fix** what you can. Items 2, 3, and 8 apply in connected mode only — in local mode, skip them (the underlying services don't exist).

1. **GitHub token expired** → run `bash bin/github-auth.sh` and report result
2. **Identity drift** → re-sync with `bash bin/person.sh sync`. This replays the
   canonical markdown identity to Supabase and the graph without creating a
   second Person node.
3. **API key missing or rejected (401/403)** *(connected mode only)* → fetch key for the config slug from API and update `.env`. Never swap a key that authenticates — slug mismatch alone is not an issue.
4. **Memory not linked** → run `/setup`
5. **Git diverged** → run `/pull`
6. **Framework outdated** → run `/update`
7. **Shell alias missing** → run `bash bin/ensure-shell-function.sh`
8. **Graph/Telegram down** *(connected mode only)* → just report. No user action.

After fixing, re-check the fixed items and report:
```
Fixed 2 of 3 issues:
✓ GitHub — re-authenticated as {login}
✓ API key — refetched, authenticates now
✗ Graph — still unreachable (API may be down)
```

## Key principle

Never tell the user to "run a command in terminal." Either fix it yourself or explain what's wrong in plain language.
