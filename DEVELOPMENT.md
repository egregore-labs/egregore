# Egregore Development Guide

> **Read this before modifying any file in `bin/` or `.claude/commands/`.**

---

## 1. Dependency Map — `bin/` Scripts

Every shell script in `bin/`, what it does, what depends on it, and what it touches.

### Core Infrastructure (LOAD-BEARING)

#### `graph.sh`
- **Purpose**: API gateway for all Neo4j queries — routes through EGREGORE_API_KEY
- **Called by**: graph-op.sh, graph-batch.sh (indirectly), enrich-graph.sh, sync-graph.sh, index-handoff.sh, graph-scribe.sh, graph-maintenance.sh, eval-op.sh, backfill-session-topics.sh, analytics-data.sh + ~30 commands
- **Commands that depend on it**: activity, add, archive, ask, character-v4, checkup, dashboard, deep-reflect, eval, graph-diagnostic, graph-maintain, handoff, harvest, ingest-google, ingest-user-interview, invite, me, meeting, onboarding, quest, quest-suggest, reflect, setup, todo + more
- **Reads**: `.env` (EGREGORE_API_KEY), `egregore.json` (api_url)
- **Writes**: Nothing
- **External deps**: curl, jq, python3, date
- **Usage**:
  ```bash
  bash bin/graph.sh test                                                    # Test connection
  bash bin/graph.sh query "MATCH (p:Person) RETURN p.name"                 # Run a Cypher query
  bash bin/graph.sh query "MATCH (p:Person {name: \$name}) RETURN p" '{"name":"alice"}'  # With parameters
  bash bin/graph.sh schema                                                 # Show schema (labels + relationships)
  ```
- **Current schema**: Person, Session, Artifact (with typed secondary labels
  such as Decision, Finding, Pattern, Claim, and Research), Quest, Project,
  Spirit, Meeting, Interview, PR, IngestSource, IngestDocument,
  IngestChunk, Connector, and SourceAccount. Connector lifecycle
  (connected mode): `(:SourceAccount {id: provider:email, status,
  authorizedAt})-[:ON]->(:Connector {id: provider})`, and
  `(:IngestSource)-[:VIA_ACCOUNT]->(:SourceAccount)` records which
  authorized account material arrived through — projected via
  `egregore-connector-lifecycle/v1` manifests through
  `bin/ingest-graph.sh apply`. Relationships include BY, CONDUCTED_BY,
  CONTRIBUTED_BY,
  FROM_MEETING, FROM_INTERVIEW, FROM_SOURCE, FROM_DOCUMENT,
  DERIVED_FROM_CHUNK, GENERATED_BY, HANDED_TO, IMPLEMENTS, INGESTED,
  INVOKED_BY, INVOLVES, MENTIONS, ON, PART_OF, PRODUCED, RELATES_TO,
  VIA_ACCOUNT, and
  STARTED_BY. Durable ingestion manifests are projected through
  `bash bin/ingest-graph.sh apply <manifest>`; route-specific writers must not
  bypass that contract.

#### `graph-batch.sh`
- **Purpose**: Execute multiple Cypher queries in a single HTTP call
- **Called by**: enrich-graph.sh, graph-maintenance.sh, sync-graph.sh, index-handoff.sh, graph-wal.sh (drain)
- **Commands that depend on it**: deep-reflect, eval, meeting, reflect + any using batch writes
- **Reads**: `.env` (EGREGORE_API_KEY), `egregore.json` (api_url)
- **Writes**: Nothing
- **External deps**: curl, jq

#### `graph-op.sh`
- **Purpose**: Versioned named graph operations. Bounded reads include
  `open-handoffs`, `pending-questions`, `lineage`, and `meeting-history`;
  `catalog` exposes their machine-readable routing contract. Writes include
  set-topic, mark-read, merge-person, claim-handoff, and create-pr.
- **Called by**: graph-maintenance.sh, activity command, pr command, wrap command, harvest command
- **Depends on**: graph.sh, graph-wal.sh
- **Reads**: Nothing directly (delegates to graph.sh)
- **Writes**: Nothing directly

#### `graph-wal.sh`
- **Purpose**: Write-Ahead Log — O(1) local buffer with async drain to graph-batch.sh
- **Called by**: graph-op.sh, pre-compact.sh, transcript-archive.sh
- **Depends on**: graph-batch.sh (for drain)
- **Reads**: Nothing
- **Writes**: WAL buffer files (local)

#### `notify.sh`
- **Purpose**: Telegram notification gateway (person DM or group fallback)
- **Called by**: ~10 commands (ask, handoff, invite, issue, quest + more)
- **Commands that depend on it**: ask, checkup, handoff, invite, issue, quest
- **Reads**: `.env` (EGREGORE_API_KEY), `egregore.json` (api_url)
- **Writes**: Nothing
- **External deps**: curl, jq
- **Usage**:
  ```bash
  bash bin/notify.sh send "alice" "Hey Alice, new handoff about MCP auth"  # DM (falls back to group)
  bash bin/notify.sh group "New quest started: research-agent"             # Group chat
  bash bin/notify.sh test                                                  # Test connection
  ```

#### `session-start.sh`
- **Purpose**: Session initialization — syncs develop, fixes API key, displays greeting, tracks health
- **Called by**: SessionStart hook (runs every session)
- **Reads**: `.env`, `egregore.json`, `.egregore-state.json`
- **Writes**: `.egregore-state.json` (auto-fix), `.egregore-session-id`, `~/.egregore/session-*.id`, `~/.egregore/boundary-*.json`, `~/.egregore/instances.json`
- **External deps**: git, curl, jq, md5, date

#### `telemetry.sh`
- **Purpose**: Privacy-respecting telemetry buffer + flush (local JSONL → API)
- **Called by**: ~12 commands (save, connect, delete-user, onboarding, archive + more)
- **Reads**: `.env` (EGREGORE_API_KEY), `egregore.json` (api_url), `.egregore-state.json`
- **Writes**: `~/.egregore/telemetry.jsonl`
- **External deps**: curl, jq, md5, date

### Session Lifecycle

#### `transcript-archive.sh`
- **Purpose**: SessionEnd hook — archives transcripts to graph + optional git repo
- **Depends on**: graph-wal.sh
- **Reads**: `egregore.json`, `.egregore-state.json`
- **Writes**: Nothing (flushes WAL)
- **External deps**: jq, git, curl, awk

#### `pre-compact.sh`
- **Purpose**: PreCompact hook — externalizes session knowledge to graph WAL before context compaction
- **Depends on**: graph-wal.sh
- **Reads**: Nothing
- **Writes**: WAL entries
- **External deps**: git, awk, grep, jq

#### `startup-check.sh`
- **Purpose**: Health checkin — validates config + phones home to API
- **Called by**: session-start.sh (fire-and-forget background)
- **Reads**: `.env`, `egregore.json`, `.egregore-state.json`
- **Writes**: Nothing
- **External deps**: git, curl, jq, uname

#### `statusline.sh`
- **Purpose**: Fast statusline renderer (branch, worktree indicator, unsaved count)
- **Called by**: Shell prompt
- **Reads**: Nothing (pure git queries)
- **Writes**: Nothing
- **External deps**: git, wc, tr, basename

### Data & Memory

#### `sync-graph.sh`
- **Purpose**: Sync all missing nodes from memory files into Neo4j
- **Depends on**: index-handoff.sh, graph.sh, graph-batch.sh
- **Reads**: `.env`, `egregore.json`, `memory/` files
- **Writes**: Nothing
- **External deps**: find, sed, grep, awk, jq

#### `index-handoff.sh`
- **Purpose**: Index a single handoff file into the graph with metadata parsing
- **Depends on**: graph-batch.sh, graph.sh
- **Reads**: Handoff markdown files
- **Writes**: Nothing
- **External deps**: jq, sed, grep

#### `enrich-graph.sh`
- **Purpose**: Backfill topics, types, timestamps, ghost resolution, RELATES_TO edges
- **Depends on**: graph.sh, graph-batch.sh
- **Reads**: `memory/` knowledge files
- **Writes**: Nothing
- **External deps**: jq, grep, sed, find

#### `graph-maintenance.sh`
- **Purpose**: Graph health scanning, issue detection, auto-repair
- **Depends on**: graph-batch.sh, graph-op.sh
- **Reads**: Nothing
- **Writes**: Nothing
- **External deps**: jq

#### `graph-scribe.sh`
- **Purpose**: Summarizes unsummarized artifacts via API (scribe spirit)
- **Depends on**: graph.sh
- **Reads**: `.env` (EGREGORE_API_KEY), `egregore.json` (api_url)
- **Writes**: Nothing
- **External deps**: curl, jq, bc

#### `graph-witness.sh`
- **Purpose**: Read-only quality evaluator for knowledge graph
- **Depends on**: graph-batch.sh
- **Reads**: Nothing
- **Writes**: `.witness-baseline.json` (baseline snapshots)
- **External deps**: jq

#### `backfill-session-topics.sh`
- **Purpose**: Backfills missing topics on Session nodes
- **Depends on**: graph.sh
- **Reads**: Nothing
- **Writes**: Nothing
- **External deps**: jq, sed

### Dashboard & Analytics

#### `activity-data.sh`
- **Purpose**: Fetches personal activity dashboard data (API + parallel git/disk ops)
- **Reads**: `.env` (EGREGORE_API_KEY), `egregore.json` (api_url, org_name)
- **Writes**: Nothing
- **External deps**: curl, git, gh, jq, date

#### `analytics-data.sh`
- **Purpose**: Org-level analytics (AM1-AM10 metrics) via parallel graph.sh calls
- **Depends on**: graph.sh (10 parallel calls)
- **Reads**: `egregore.json` (org_name)
- **Writes**: Nothing
- **External deps**: jq

#### `dashboard-data.sh`
- **Purpose**: Personal dashboard data (API + git/worktree status)
- **Reads**: `.env` (EGREGORE_API_KEY), `egregore.json` (api_url, org_name)
- **Writes**: Nothing
- **External deps**: curl, jq, git, date, md5

### Security & Isolation

#### `boundary.sh`
- **Purpose**: Path validation for environment isolation (multi-tenant safety)
- **Called by**: PreToolUse hook (boundary-check.sh)
- **Reads**: `egregore.json` (repos[])
- **Writes**: Nothing
- **External deps**: jq, realpath
- **Session boundary** = this project directory + memory directory (resolved symlink) + managed repos from `egregore.json`
- **Allowed paths**: this project dir, memory repo (via symlink), managed repos in `egregore.json` → `repos[]`, `~/.claude`, `/tmp`, system paths (`/usr`, `/etc`, `/bin`)
- **Two-tier enforcement** (boundary-check.sh, decided 2026-07-08 — see `memory/knowledge/decisions/2026-07-08-boundary-hook-consent-design.md`):
  - **Hard tier — other Egregore instance directories** (from `~/.egregore/instances.json`): denied for every tool including Bash (path-literal grep). No consent path.
  - **Soft tier — everything else outside the boundary**: consent-gated for every tool. Read roots (`~/Downloads`, `~/Desktop` by default) are readable without consent; other reads and all outside writes prompt a consent flow whose grant lands in `.egregore-boundary-consent` (session) or `.egregore-boundary.local.json` (instance). Bash is checked best-effort for user-home path literals — a miss degrades to "no prompt", never a hard-tier breach.
- **Posture** `strict | standard | open` + `locked` from `egregore.json` → `boundary { posture, read[], locked }` merged with the personal local file at session start into `/tmp/egregore-boundary-*.json`. `open` allows outside reads (writes still gated); sessions in `bypassPermissions` skip the soft tier entirely; `locked: true` disables personal extensions, consent, and bypass relaxation — hard tier only ever says no.

#### `preflight.sh`
- **Purpose**: Multi-tenancy violation detection (hardcoded orgs, direct API calls)
- **Reads**: `egregore.json`
- **Writes**: Nothing
- **External deps**: jq, grep, sed

### Authentication & Setup

#### `github-auth.sh`
- **Purpose**: GitHub device flow OAuth to get GITHUB_TOKEN
- **Called by**: onboarding, checkup, setup commands
- **Reads**: Nothing
- **Writes**: `.env` (GITHUB_TOKEN), git credential store
- **External deps**: curl, jq, pbcopy/xclip, open/xdg-open, sed, git

#### `ensure-shell-function.sh`
- **Purpose**: Installs `egregore` shell alias to ~/.zshrc/.bashrc/.config/fish
- **Reads**: `egregore.json` (slug)
- **Writes**: Shell config files
- **External deps**: jq, grep, sed

### Deployment

#### `deploy-site.sh`
- **Purpose**: Sync site contents from egregore-site to egregore-site repo
- **Reads**: `.env` (GITHUB_TOKEN), `egregore.json`
- **Writes**: Nothing (pushes to remote)
- **External deps**: git, rsync, sed, jq, curl, grep

#### `provision-hosted.sh`
- **Purpose**: Provision hosted Egregore VPS for an org via API
- **Reads**: `.env` (GITHUB_TOKEN), `egregore.json` (api_url, slug, repo_name)
- **Writes**: Nothing
- **External deps**: curl, jq

#### `workspace-init.py`
- **Purpose**: Python workspace init for Coder VPS (fetches config from API)
- **Reads**: Nothing (fetches from API)
- **Writes**: `egregore.json`, `.env`, `.egregore-state.json`
- **External deps**: urllib, json, os

#### `workspace-init.sh`
- **Purpose**: Bash wrapper for workspace init on Coder VPS
- **Depends on**: workspace-init.py
- **Reads**: Nothing
- **Writes**: `~/.git-credentials`, git config
- **External deps**: git, curl, jq

### Evaluation

#### `eval-op.sh`
- **Purpose**: Named graph operations for eval pipeline (create runs/matches/reports)
- **Depends on**: graph.sh
- **Reads**: Nothing
- **Writes**: Nothing
- **External deps**: jq

### Content Ingestion

#### Granola (MCP)
- **Purpose**: Meeting data access via Granola's official MCP server
- **Server**: `https://mcp.granola.ai/mcp` (configured in `.claude/mcp.json`)
- **Auth**: OAuth 2.0 browser-based (via `/mcp` → Authenticate)
- **Tools**: `list_meetings`, `get_meetings`, `get_meeting_transcript`, `query_granola_meetings`
- **Setup**: `/connect granola`

#### Notion (MCP)
- **Purpose**: Search and fetch selected Notion pages through Notion's official hosted MCP; `/ingest notion` reviews and writes approved pages into Egregore memory
- **Server**: `https://mcp.notion.com/mcp`
- **Auth**: User OAuth owned by Notion and the current agent runtime; Egregore Labs has no Notion OAuth app or token broker
- **Tools**: `notion-search`, `notion-fetch` (OpenAI clients may expose them as `search`, `fetch`)
- **Setup**: `/ingest notion` guides connection automatically; `/connect notion` remains a direct entry point

#### `connector-google.sh`
- **Purpose**: Wrapper delegating to TypeScript connector implementation
- **Reads**: Nothing
- **Writes**: Nothing
- **External deps**: npx, tsx

#### `connect-refresh.sh`
- **Purpose**: Fire-and-forget Connect overlay refresh at session start — connected instances pick up newly released Connect skills without re-running the launcher (`npx create-egregore --refresh-connect`)
- **Called by**: session-start.sh, codex-session-start.sh (Pi delegates)
- **Reads**: `egregore.json` (mode/api_url)
- **Writes**: `.egregore/connect-refresh.log`, Connect overlay skill files
- **External deps**: npx

#### `connector-notion.sh`
- **Purpose**: Legacy direct-REST connector retained temporarily for rollback and comparison while the MCP ingestion path is smoke-tested (spec: `docs/specs/notion-connector.md`)
- **Called by**: No active skill; pending removal after MCP verification
- **Reads**: `.env` (`NOTION_API_TOKEN`), `egregore.json` (`connectors.notion`), `.egregore-state.json`
- **Writes**: `.env` (auth set), `.egregore-state.json` (notion_* keys), `~/.egregore/context/notion/` cache, export dirs
- **External deps**: npx, tsx

### Worktree & Git

#### `worktree.sh`
- **Purpose**: Worktree lifecycle management (setup symlinks, cleanup, orphan detection)
- **Called by**: branch command, CLAUDE.md worktree flow
- **Reads**: Nothing
- **Writes**: Symlinks in worktree directories
- **External deps**: realpath, ln, ps, lsof, git, rm, stat

#### `save-reminder.sh`
- **Purpose**: Gentle nudge when there are unsaved changes (cooldown-aware)
- **Called by**: Stop hook
- **Reads**: Nothing
- **Writes**: Nothing
- **External deps**: git, md5sum, stat, date

### Tests

#### `test-changes.sh`
- **Purpose**: Static analysis — Cypher safety, bash compat, direct API calls
- **Run**: `bash bin/test-changes.sh [--all|file1 file2]`
- **Exit**: 0 = no FAILs, 1 = any FAILs
- **Checks**: date() guards, LIMIT clauses, coalesce() on collections, macOS compat, direct curl blocking

#### `test-isolation.sh`
- **Purpose**: Live E2E API testing — org registration, graph isolation, key security
- **Run**: `bash bin/test-isolation.sh [--no-cleanup]`
- **Prereqs**: `.env` (both tokens), `egregore.json` (api_url)
- **Note**: Creates/deletes test org. 11 phases.

#### `test-onboarding.sh`
- **Purpose**: State machine validation — onboarding phases, cross-references, contracts
- **Run**: `bash bin/test-onboarding.sh`
- **Checks**: 19 tests covering state transitions, CLAUDE.md integrity, API alignment

#### `test-startup.sh`
- **Purpose**: Session-start reliability — exit codes, ASCII art, branch consistency
- **Run**: `bash bin/test-startup.sh [count]` (default: 5 runs)

#### `test-hetzner.sh`
- **Purpose**: Minimal Hetzner Cloud API test (create + delete server)
- **Run**: `bash bin/test-hetzner.sh`
- **Prereqs**: `HETZNER_API_TOKEN` env var

---

## 2. Load-Bearing Files

Modify with extreme care. Breakage here cascades across the entire system.

| File | Why it's critical | Dependents |
|------|-------------------|------------|
| `bin/graph.sh` | Every graph query routes through it | ~35 scripts + ~30 commands |
| `bin/graph-batch.sh` | All batch graph writes | ~20 scripts |
| `bin/graph-op.sh` | Named graph operations | ~15 commands |
| `bin/graph-wal.sh` | Write-Ahead Log for resilience | graph-op, pre-compact, transcript-archive |
| `bin/notify.sh` | All Telegram notifications | ~10 commands |
| `bin/session-start.sh` | Runs every session, writes session state | Everything downstream |
| `bin/telemetry.sh` | All event tracking | ~12 commands |
| `bin/boundary.sh` | Multi-tenant isolation enforcement | PreToolUse hook (every tool call) |
| `bin/worktree.sh` | Worktree lifecycle | branch command, CLAUDE.md flow |
| `.claude/hooks/boundary-check.sh` | Path safety on every tool use | All file operations |
| `.claude/hooks/branch-guard.sh` | Prevents commits to protected branches | All git operations |
| `.claude/hooks/observe.sh` | Telemetry observation layer | All Edit/Write/Bash calls |
| `.claude/hooks/subagent-context.sh` | Injects org context into subagents | All subagent launches |
| `CLAUDE.md` | Framework behavior contract | Every session |

---

## 3. Critical Rules

### Before modifying `bin/` or commands

1. **Read this file first.** Check the dependency map to understand what your change affects.
2. **Plan first, implement one step at a time.** Multi-file changes are where things break.
3. **Git checkpoint before any multi-file change.** Commit or stash current work.

### After ANY change — run the Python test suite

The **primary test suite** is pytest in `tests/` with its own venv (437 tests). This is the canonical source of truth.

```bash
# PRIMARY: Python pytest suite (437 tests — API, isolation, security, flows)
cd tests && .venv/bin/pytest -q --tb=short

# Run specific test categories
.venv/bin/pytest -q -m security       # Security tests
.venv/bin/pytest -q -m isolation       # Cross-tenant isolation
.venv/bin/pytest -q -m api             # API endpoint tests
.venv/bin/pytest -q -m flow            # End-to-end flows
.venv/bin/pytest -q -m capture         # Capture reliability
.venv/bin/pytest -q -m sync            # Sync accuracy
.venv/bin/pytest -q -m quality         # Data quality

# Run a single test file
.venv/bin/pytest test_guard.py -q
```

**Test files** (in `tests/`):
| File | What it tests |
|------|---------------|
| `test_capture.py` | Memory capture reliability |
| `test_full_flow.py` | End-to-end API flows |
| `test_guard.py` | API guard layer (auth, scoping) |
| `test_health_dashboard.py` | Health checkin + admin dashboard |
| `test_install_flows.py` | Founder/joiner install paths |
| `test_invite_flow.py` | Invite + onboarding chain |
| `test_org_scope.py` | Cypher org-scoping rewriter |
| `test_quality.py` | Data quality metrics |
| `test_retrieval.py` | Retrieval stability |
| `test_security.py` | Secrets detection, codebase security |
| `test_self_serve.py` | Self-serve workspace + Coder integration |
| `test_session_topic.py` | Session topic extraction |
| `test_setup_integration.py` | Setup flow integration |
| `test_sync.py` | Sync accuracy |
| `test_tenant_isolation.py` | Neo4j org scoping isolation |
| `test_tokens.py` | API key format + validation |
| `test_transcripts.py` | Transcript archival security |

Also: `telegram-bot/test_bot.py` and `telegram-bot/test_org_isolation.py` for bot tests.

### Supplementary: bash test scripts in `bin/`

These are **in addition to** the Python suite, not a replacement:

```bash
# Static analysis (fast, checks changed files for antipatterns)
bash bin/test-changes.sh --all

# If you touched session-start.sh
bash bin/test-startup.sh

# If you touched onboarding or state machine
bash bin/test-onboarding.sh

# If you touched isolation/boundary logic (live E2E — creates test org)
bash bin/test-isolation.sh
```

### Hard rules

- **NEVER modify load-bearing files without running the full test suite.**
- **NEVER delete working tests.** If a test is wrong, fix it — don't remove it.
- **NEVER change `graph.sh` or `notify.sh` signature/behavior** without checking all callers.
- **NEVER add `source .env`** — use `grep '^KEY=' .env | cut -d'=' -f2-` pattern (breaks on spaces otherwise).
- **NEVER construct direct curl calls to Neo4j or Telegram** — use `bin/graph.sh` and `bin/notify.sh`.
- **NEVER use macOS-incompatible bash** — no `date +%N`, no `sed -i` without `''` backup arg.
- **NEVER modify `~/.egregore/instances.json`** — managed exclusively by session-start.sh.
- **Always use `bin/graph.sh`** for Cypher queries — it handles auth, routing, and error formatting.
- **Cypher safety**: Always guard `date()` with `toString()`, collection access with `coalesce()`, and use LIMIT on MATCH queries.

---

## 4. State Files

### `.env` (gitignored — personal secrets)

| Key | Purpose | Who reads | Who writes |
|-----|---------|-----------|------------|
| `GITHUB_TOKEN` | GitHub API auth | session-start, github-auth, deploy-site, test-isolation | github-auth.sh, onboarding |
| `EGREGORE_API_KEY` | API gateway auth | graph.sh, notify.sh, telemetry.sh, session-start, all infra | onboarding, session-start (auto-fix) |
| `NOTION_API_TOKEN` | Notion internal-integration token (client-owned; same var the official `ntn` CLI reads) | connector-notion | connector-notion (`auth set` hidden prompt) |

**Template**: `.env.example` / `.env 2.example`

### `egregore.json` (committed — non-secret org config)

| Key | Purpose | Who reads |
|-----|---------|-----------|
| `org_name` | Display name | analytics-data, subagent-context |
| `github_org` | GitHub org name | session-start, subagent-context |
| `memory_repo` | Memory repo URL | session-start (sync) |
| `api_url` | API gateway URL | graph.sh, notify.sh, telemetry.sh, all infra |
| `slug` | Org identifier | session-start, provision-hosted, ensure-shell-function |
| `repo_name` | Hub repo name | provision-hosted |
| `repos[]` | Managed repos list | session-start, boundary.sh |
| `connectors` | External service config | connector-google, connector-notion |

**Written by**: Founders during setup (manual or onboarding flow).

### `.egregore-state.json` (gitignored — user identity & consent)

| Key | Purpose | Who reads | Who writes |
|-----|---------|-----------|------------|
| `github_username` | GitHub handle | session-start | session-start (auto-provision) |
| `display_name` | User display name | branch-guard, commands | onboarding, /me |
| `usage_type` | Role (founder/joiner) | branch-guard | onboarding |
| `onboarding_complete` | Gate for onboarding flow | session-start | onboarding |
| `session_tracking` | Consent flag | session-start | onboarding (consent phase) |
| `transcript_sharing` | Consent flag | transcript-archive | onboarding (consent phase) |
| `telemetry` | Consent flag | telemetry.sh | onboarding (consent phase) |
| `connected_services` | Connector status (granola, google) | connect.md | User config |
| `notion_connector`, `notion_auth_complete`, `notion_workspace`, `notion_last_sync` | Notion connector state | connect skill, ingest-notion skill, connector-notion | connector-notion |

### `.egregore-session-id` (gitignored — current session)

Single line: `20260316T170632-oguzhan-4709` (ISO timestamp, author, PID)

| Who reads | Who writes |
|-----------|------------|
| observe.sh, subagent-context.sh, telemetry.sh, commands | session-start.sh |

### Runtime/Cached Files

| File | Purpose | Lifespan |
|------|---------|----------|
| `/tmp/egregore-boundary-*.json` | Boundary check cache | Per session |
| `/tmp/egregore-obs-*.jsonl` | Tool use observation buffer | Per session (flushed at end) |
| `~/.egregore/session-*.id` | Global session registry | Per session |
| `~/.egregore/instances.json` | Multi-instance registry | Persistent (DO NOT MODIFY) |
| `~/.egregore/telemetry.jsonl` | Telemetry buffer | Flushed at session end |
| `.witness-baseline.json` | Graph quality baseline | Persistent |

---

## 5. Command → Script Dependency Map

Commands that trigger the most infrastructure:

| Command | bin/ scripts used |
|---------|-------------------|
| `/save` | telemetry.sh, (git operations) |
| `/handoff` | graph.sh, notify.sh, index-handoff.sh, telemetry.sh |
| `/activity` | activity-data.sh, graph-op.sh |
| `/dashboard` | dashboard-data.sh |
| `/reflect` | graph.sh, graph-batch.sh, telemetry.sh |
| `/deep-reflect` | graph.sh, graph-batch.sh, telemetry.sh |
| `/meeting` | Granola MCP, graph.sh, graph-batch.sh, telemetry.sh |
| `/onboarding` | graph.sh, github-auth.sh, telemetry.sh |
| `/checkup` | github-auth.sh, graph.sh, notify.sh, ensure-shell-function.sh |
| `/setup` | graph.sh, sync-repos.sh, github-auth.sh |
| `/invite` | graph.sh, notify.sh |
| `/quest` | graph.sh, notify.sh |
| `/branch` | worktree.sh, graph-op.sh |
| `/pr` | graph-op.sh |
| `/graph-maintain` | graph-maintenance.sh |
| `/graph-diagnostic` | graph.sh |

---

## 6. Hook Files (`.claude/hooks/`)

| Hook | Type | Purpose | Scripts called |
|------|------|---------|----------------|
| `boundary-check.sh` | PreToolUse | Environment isolation | None (local path checks) |
| `branch-guard.sh` | PreToolUse | Protect main/develop | None (reads state file) |
| `observe.sh` | PostToolUse | Telemetry + drift detection | git fetch (background) |
| `subagent-context.sh` | SubagentStart | Inject org context | None (file reads only) |

Session lifecycle hooks (configured in `.claude/settings.json`, not in hooks/ dir):
- **SessionStart** → `bin/session-start.sh`
- **SessionEnd** → `bin/transcript-archive.sh`
- **PreCompact** → `bin/pre-compact.sh`
- **Stop** → `bin/save-reminder.sh`

---

## 7. Dependency Graph (Visual)

```
session-start.sh ─┬─→ .egregore-state.json
                   ├─→ .egregore-session-id
                   ├─→ boundary cache
                   └─→ startup-check.sh (background)

graph.sh ←──── graph-op.sh ←── graph-maintenance.sh
    ↑               ↑               ↑
    │               │               │
graph-batch.sh ←── graph-wal.sh ←── pre-compact.sh
    ↑                                    ↑
    │                              transcript-archive.sh
    │
sync-graph.sh ←── index-handoff.sh
enrich-graph.sh
graph-witness.sh
graph-scribe.sh

notify.sh ←── (ask, handoff, invite, issue, quest commands)

telemetry.sh ←── (all slash commands, fire-and-forget)
```

---

## 8. Setup & Join Flows

Three flows bring users into Egregore. Each is documented end-to-end with every API call, file write, and external service interaction.

### GitHub OAuth Scopes

| Context | Scopes | Why |
|---------|--------|-----|
| `bin/github-auth.sh` (device flow) | `repo,read:org` | Clone private repos, read org membership |
| `create-egregore` (device flow) | `repo,read:org` | Same — identical client ID `Ov23lizB4nYEeIRsHTdb` |
| Website OAuth (egregore.xyz) | `repo,read:org` | Same scopes, web-based flow instead of device flow |
| `gh auth login` (local mode) | `repo,read:org` | Minimum needed: clone repos + accept invitations |
| `/invite` (adding collaborators) | `repo` on inviter's token | GitHub API: add collaborator to repo + memory repo |

### Supabase Tables → Local File Equivalents

| Supabase table | Local equivalent | Notes |
|----------------|------------------|-------|
| `orgs` | `egregore.json` | org_name, github_org, slug, api_url, repos |
| `users` | `memory/people/{github}.md` | Profile, role, joined date |
| `memberships` | `egregore.json` + `memory/people/` | Membership implied by repo access + person file |
| `api_keys` | Not needed locally | API key only for gateway auth |
| `setup_tokens` | Not needed locally | Single-use bootstrap tokens |
| `orgs.hosting_*` | Not needed locally | Coder VPS metadata |

---

### A) Website Setup Flow (Founder)

**Trigger**: User visits egregore.xyz/setup → GitHub OAuth → selects org → creates instance.

| # | Step | What Happens | External Service | Data Created | Local Mode |
|---|------|-------------|-----------------|-------------|------------|
| 1 | **GitHub OAuth** | User authenticates via web OAuth (same `repo,read:org` scopes) | GitHub OAuth | `github_token` in API memory | ESSENTIAL — need token for git ops |
| 2 | **Detect orgs** | `GET /api/org/setup/orgs` — API calls GitHub to list user's orgs, checks each for existing Egregore instances | GitHub API (`/user/orgs`, `/repos`) | Org list with `has_egregore` flags | REPLACEABLE — `gh api /user/orgs` locally |
| 3 | **Repo picker** | `GET /api/org/setup/repos?org=X` — lists org repos for managed repo selection | GitHub API (`/orgs/{org}/repos`) | User's repo selection | REPLACEABLE — `gh repo list {org}` locally |
| 4 | **Create instance** | `POST /api/org/setup` with `{github_org, org_name, repos[], instance_name, transcript_sharing}` | — | — | — |
| 4a | ↳ Generate from template | `gh.generate_from_template()` — creates `{org}/egregore` from `egregore-labs/egregore` template | GitHub API (POST `/repos/{template}/generate`) | New repo `{org}/egregore` | ESSENTIAL — `gh repo create --template` |
| 4b | ↳ Create memory repo | `gh.create_repo()` — creates `{org}/{org}-memory` | GitHub API (POST `/orgs/{org}/repos`) | New repo `{org}/{org}-memory` | ESSENTIAL — `gh repo create` |
| 4c | ↳ Init memory structure | `gh.init_memory_structure()` — commits initial directory structure via GitHub Contents API | GitHub API (PUT `/repos/{org}/{repo}/contents/`) | `people/`, `handoffs/`, `knowledge/`, `quests/` dirs + README | ESSENTIAL — `git init` + push |
| 4d | ↳ Generate API key | `generate_api_key(slug)` → format `ek_{slug}_{random}` | — | Key in memory | SKIPPABLE — no API gateway needed |
| 4e | ↳ Persist to Supabase | `sb.create_org()`, `sb.create_api_key()`, `sb.upsert_user()`, `sb.add_membership()` | Supabase | `orgs` row, `api_keys` row, `users` row, `memberships` row | SKIPPABLE — use egregore.json + memory/people/ |
| 4f | ↳ Bootstrap Neo4j | `MERGE (o:Org {id: $slug}) SET o.name, o.github_org, o.api_key` | Neo4j (via API) | Org node | SKIPPABLE — graph is for queries, not required |
| 4g | ↳ Update egregore.json | `gh.update_egregore_json()` — writes org config to repo via GitHub Contents API | GitHub API | `egregore.json` in repo | ESSENTIAL — but can write locally |
| 4h | ↳ Sync develop branch | `gh.sync_branch_to_main()` — ensures develop matches main | GitHub API | Branch sync | ESSENTIAL — `git push origin main:develop` |
| 4i | ↳ Generate setup token | `create_token({fork_url, memory_url, api_key, ...})` → `st_{random}` | Supabase (`setup_tokens` table) | Token + payload | REPLACEABLE — encode config directly |
| 4j | ↳ Provision VPS (optional) | If `hosting=true`: `provision_vps()` → Hetzner API → Coder install | Hetzner, Coder | VPS, Coder instance | SKIPPABLE — local mode only |
| 5 | **Display token** | Website shows `npx create-egregore --token st_xxxx` command | — | — | — |
| 6 | **User runs CLI** | → Flow B below | — | — | — |

---

### B) CLI Join Flow (`npx create-egregore`)

**Trigger**: User runs `npx create-egregore --token st_xxxx` (from website) or `npx create-egregore` (interactive).

#### Token Flow (primary path)

| # | Step | What Happens | External Service | Data Created | Local Mode |
|---|------|-------------|-----------------|-------------|------------|
| 1 | **Claim token** | `GET /api/org/claim/{token}` — returns full config payload | Egregore API + Supabase | Token consumed (single-use) | REPLACEABLE — config can be passed directly |
| 2 | **GitHub auth** (joiners only) | If `!data.github_token`: runs device flow → `POST github.com/login/device/code` + poll | GitHub OAuth | `github_token` | ESSENTIAL |
| 3 | **Accept invitations** | `GET /user/repository_invitations` + `PATCH /user/repository_invitations/{id}` | GitHub API | Invitation accepted | ESSENTIAL — needed to access private repos |
| 4 | **Clone fork** | `git clone https://x-access-token:{token}@github.com/{org}/{repo}.git` | GitHub (HTTPS) | Local repo at `./{repo}/` | ESSENTIAL |
| 5 | **Set git identity** | `git config user.name`, `git config user.email` (repo-local) | — | `.git/config` | ESSENTIAL |
| 6 | **Clone memory** | `git clone https://x-access-token:{token}@github.com/{org}/{org}-memory.git` | GitHub (HTTPS) | Local repo at `./{org}-memory/` | ESSENTIAL |
| 7 | **Create symlink** | `ln -s ../{org}-memory ./{repo}/memory` | — | Symlink | ESSENTIAL |
| 8 | **Write .env** | `GITHUB_TOKEN={token}\nEGREGORE_API_KEY={api_key}` (mode 0600) | — | `.env` | ESSENTIAL (token) / SKIPPABLE (api_key) |
| 9 | **Write state** | `{github_username, onboarding_complete: false, usage_type: "joiner_group", ...}` | — | `.egregore-state.json` | ESSENTIAL |
| 10 | **Register instance** | Writes to `~/.egregore/instances.json` | — | Registry entry | ESSENTIAL (multi-instance isolation) |
| 11 | **Shell alias** | Appends `alias egregore='cd ... && claude start'` to `~/.zshrc` | — | Shell profile line | ESSENTIAL |
| 12 | **Clone managed repos** | For each repo in config: `git clone` | GitHub (HTTPS) | Local repos at `./{repo}/` | ESSENTIAL (if repos exist) |
| 13 | **Done** | Prints "Egregore is ready" + workspace layout | — | — | — |

#### Interactive Flow (fallback — no token)

| # | Step | What Happens | External Service | Data Created | Local Mode |
|---|------|-------------|-----------------|-------------|------------|
| 1 | **GitHub auth** | Device flow (same as above) | GitHub OAuth | `github_token` | ESSENTIAL |
| 2 | **Detect orgs** | `GET /api/org/setup/orgs` | Egregore API + GitHub API | Org list | REPLACEABLE — `gh api /user/orgs` |
| 3 | **User picks** | Interactive menu: join existing / set up new | — | User choice | — |
| 4a | **If "Set up new"** | Prompts for org name, instance name, repos, transcript consent → `POST /api/org/setup` → claim token → install | All (Flow A + B) | Full org | See Flow A |
| 4b | **If "Join existing"** | `POST /api/org/join` with `{github_org, repo_name}` | Egregore API | Setup token | REPLACEABLE |
| 5 | **Install** | Same as token flow steps 3-13 | — | — | — |

**`POST /api/org/join` backend** (for joiners):
1. Verify repo exists via GitHub API
2. Read `egregore.json` from repo via GitHub Contents API
3. Look up org's API key from Supabase/memory
4. Register user + membership in Supabase
5. If hosting enabled: create Coder user + workspace
6. Generate joiner setup token (no `github_token` embedded — CLI handles auth)
7. Return `{setup_token, fork_url, memory_url}`

---

### C) Invite Flow (`/invite` → invitee joins)

#### Inviter Side

| # | Step | What Happens | External Service | Data Created | Local Mode |
|---|------|-------------|-----------------|-------------|------------|
| 1 | **Read config** | Reads `GITHUB_TOKEN`, `EGREGORE_API_KEY` from `.env`; `github_org`, `api_url`, `slug`, `repo_name` from `egregore.json` | — | — | ESSENTIAL |
| 2 | **Send invite** | `POST /api/org/invite` with `{github_org, github_username, repo_name, slug, github_token}` | Egregore API | — | — |
| 2a | ↳ GitHub org invite | API uses inviter's token to add collaborator to `{org}/{repo}` + `{org}/{org}-memory` | GitHub API (PUT `/repos/{org}/{repo}/collaborators/{user}`) | Repo collaboration invite | ESSENTIAL — `gh api` locally |
| 2b | ↳ Generate invite token | API creates setup token for the invitee (joiner type, no github_token embedded) | Supabase (`setup_tokens`) | `st_xxxx` token | REPLACEABLE — can skip token |
| 2c | ↳ Supabase upsert | `upsert_user(github_username)` — pre-register user | Supabase | `users` row | SKIPPABLE |
| 3 | **Record in graph** | `MERGE (p:Person {github: $github}) ON CREATE SET p.invited = date(), p.invitedBy = $inviter` | Neo4j (via `graph.sh`) | Person node | SKIPPABLE |
| 4 | **Supabase sync** | `POST /api/user/ensure` — sync user to Supabase (non-fatal) | Supabase (via API) | User record | SKIPPABLE |
| 5 | **Telegram notify** | Query graph for `telegramId`, if found: `bin/notify.sh send "{user}" "You've been invited..."` | Neo4j + Telegram | DM or group message | SKIPPABLE |
| 6 | **Coder provision** | If hosting enabled: `GET /api/hosting/info/{slug}`, then `POST /api/hosting/user/{slug}` | Coder API | Coder user account | SKIPPABLE |
| 7 | **Display result** | Shows invite URL, invite token, instructions for invitee | — | — | — |

#### Invitee Side

| # | Step | What Happens | External Service | Data Created | Local Mode |
|---|------|-------------|-----------------|-------------|------------|
| 1 | **Receive invite** | Gets URL/token via Telegram, email, or direct message from inviter | — | — | — |
| 2 | **Accept GitHub invite** | Clicks link in GitHub notification email, or `create-egregore` auto-accepts | GitHub | Repo access granted | ESSENTIAL |
| 3 | **Run CLI** | `npx create-egregore --token st_xxxx` or `npx create-egregore` (interactive → picks "Join existing") | — | — | — |
| 4 | **Install** | Same as Flow B (token or interactive) | All of Flow B | Full local workspace | See Flow B |
| 5 | **First session** | `session-start.sh` runs → detects `onboarding_complete: false` → triggers `/onboarding` | — | — | — |
| 6 | **Onboarding** | 7-phase state machine: VERIFY → WELCOME → HARVEST_IDENTITY → HARVEST_CONNECTION → CONSENT → ORIENT → COMPLETE | Neo4j, Supabase, Telegram | Person node, person file, state file, shell alias | Mixed (see below) |

**Onboarding service dependencies:**

| Phase | External Services | Local Mode |
|-------|-------------------|------------|
| VERIFY | None (local file checks) | ESSENTIAL |
| WELCOME | None (display egregore.md) | ESSENTIAL |
| HARVEST_IDENTITY | Supabase via `/api/user/ensure` | SKIPPABLE (just save to state file) |
| HARVEST_CONNECTION | None (save to state file) | ESSENTIAL |
| CONSENT | None (save to state file) | ESSENTIAL |
| ORIENT | Neo4j (query active quests + recent sessions) | SKIPPABLE (read from memory/ files) |
| COMPLETE | Neo4j (MERGE Person), Supabase (`/api/user/ensure`), Telegram (optional), `memory/` git push | Mixed — Neo4j/Supabase SKIPPABLE, memory push ESSENTIAL |

---

### `create-egregore` Package Details

Lives at `packages/create-egregore/` in this repo (published to npm as `create-egregore`, currently v0.3.14).

**Structure:**
```
packages/create-egregore/
├── bin/cli.js       — Entry point (two modes: --token or interactive)
├── lib/api.js       — HTTP client (claimToken, getOrgs, setupOrg, joinOrg)
├── lib/auth.js      — GitHub device flow (same client_id as github-auth.sh)
├── lib/setup.js     — Local install (clone, symlink, .env, state, alias)
├── lib/ui.js        — Terminal UI (spinners, prompts, banners)
└── package.json     — Zero runtime dependencies
```

**API endpoints used:**
| Endpoint | Method | Auth | Purpose |
|----------|--------|------|---------|
| `/api/org/claim/{token}` | GET | None (token is auth) | Claim setup token, get full config |
| `/api/org/setup/orgs` | GET | GitHub token | List user's orgs + Egregore status |
| `/api/org/setup/repos` | GET | GitHub token | List repos in an org |
| `/api/org/setup` | POST | GitHub token | Founder: create new instance |
| `/api/org/join` | POST | GitHub token | Joiner: join existing instance |
| `/api/auth/github/client-id` | GET | None | Get OAuth client ID |
| `/api/auth/github/callback` | POST | None | Exchange device code for token |

---

## 9. Memory Repository Structure

`memory/` is a **symlink** to a separate git repository (e.g., `../{org}-memory/`). This repo is shared across all team members and synced on every session by `session-start.sh` (git fetch + pull on main).

### Directory Layout

```
memory/
├── MEMORY.md              — Claude's auto-memory index (loaded into context)
├── README.md              — Memory repo overview
├── activity.json          — Cached activity data
├── pins.json              — Pinned items for dashboard
│
├── people/                — Team directory
│   ├── index.md           — Member listing
│   ├── oz.md              — Individual profiles
│   ├── cem.md
│   └── ...
│
├── handoffs/              — Session summaries & async handoffs
│   ├── index.md           — Reverse-chronological one-line summaries
│   ├── 2026-01/           — Organized by month
│   ├── 2026-02/
│   ├── 2026-03/
│   └── {date}-{topic}.md  — Standalone handoffs (older format)
│
├── knowledge/             — Organized learning
│   ├── decisions/         — Formal decisions with rationale
│   ├── findings/          — Discoveries and learnings
│   ├── patterns/          — Recurring structures & best practices
│   ├── issues/            — Tracked problems
│   ├── questions/         — Open inquiries
│   ├── research/          — Research notes
│   ├── evals/             — Evaluation results
│   └── tmp/               — Scratch space
│
├── quests/                — Open-ended explorations
│   ├── index.md           — Active/paused/completed tables
│   ├── _template.md       — Quest template
│   └── {slug}.md          — Individual quests
│
├── wraps/                 — Session completion logs
│   ├── 2026-02/
│   └── 2026-03/
│       └── DD-author-topic.md
│
├── artifacts/             — Long-form documents & captured sources
│   ├── README.md
│   └── YYYY-MM-DD-author-title.md
│
├── projects/              — Project reference docs
│   ├── egregore.md
│   ├── lace.md
│   ├── tristero.md
│   ├── infrastructure.md
│   └── research.md
│
├── meetings/              — Ingested meeting transcripts
│   └── YYYY-MM-DD-topic.md
│
├── research/              — User interview data
│   ├── interviews/
│   │   ├── index.md
│   │   └── YYYY-MM-DD-name.md
│   └── participants/
│       └── name.md
│
├── onboarding/            — Orientation guides
│   └── README.md
│
├── comms/                 — Communication strategy docs
├── analytics/             — Analytics reports
├── conversations/         — Threaded conversations
│   └── YYYY-MM/
│       └── DD-author-topic.md
└── diagnostics/           — Graph diagnostic reports
```

### Directory Details

#### `people/` — Team Directory
- **Written by**: `/onboarding` (COMPLETE phase), manual edits
- **Format**: Lightweight markdown profile
- **Frontmatter**: None (plain markdown)
- **Example** (`oz.md`):
  ```markdown
  # Oz
  Joined: 2026-02-06
  ```
- **Example** (`cem.md`):
  ```markdown
  # Cem
  Role: Research & Architecture
  Focus: Knowledge graphs, organizational intelligence
  Joined: 2026-01-26
  ```

#### `handoffs/` — Session Summaries
- **Written by**: `/handoff` command, `/save` (if handoff created)
- **Index**: `index.md` — reverse-chronological, one line per handoff
- **Format**: `YYYY-MM-DD-author-topic.md` or `DD-author-topic.md` (in monthly dirs)
- **Frontmatter**:
  ```yaml
  From: oz
  To: cem, ali
  Date: 2026-03-05
  Branch: dev/oz/google-connector
  ```
- **Sections**: Briefing, Key Decisions, Current State, Open Threads, Next Steps
- **Synced by**: `bin/index-handoff.sh` (indexes into Neo4j graph)

#### `knowledge/decisions/` — Formal Decisions
- **Written by**: `/reflect` (when type is decision)
- **Format**: `YYYY-MM-DD-topic.md`
- **Frontmatter**:
  ```yaml
  Date: 2026-02-07
  Author: cem
  Category: decision
  Status: Final
  ```
- **Sections**: Executive summary, analysis, alternatives, rationale

#### `knowledge/findings/` — Discoveries
- **Written by**: `/reflect` (when type is finding), `/deep-reflect`
- **Format**: `YYYY-MM-DD-topic.md`
- **Frontmatter**:
  ```yaml
  type: finding
  author: oz
  created: 2026-03-07
  confidence: high
  source: meeting
  topics: [partnerships, design]
  conviction: strong
  urgency: high
  ```

#### `knowledge/patterns/` — Best Practices
- **Written by**: `/reflect` (when type is pattern), `/archive`
- **Format**: `topic.md` (no date prefix — patterns are evergreen)
- **Frontmatter**:
  ```yaml
  title: Atomic PRs
  author: oz
  date: 2026-02-10
  type: pattern
  ```
- **Sections**: Anti-pattern, case study, the fix

#### `knowledge/issues/` — Tracked Problems
- **Written by**: `/issue` command
- **Format**: `YYYY-MM-DD-topic.md`

#### `knowledge/questions/` — Open Inquiries
- **Written by**: Manual or `/reflect`
- **Format**: `YYYY-MM-DD-topic.md`

#### `quests/` — Open-Ended Explorations
- **Written by**: `/quest new`, `/quest contribute`
- **Template**: `_template.md`
- **Frontmatter**:
  ```yaml
  title: Member Lifecycle
  slug: member-lifecycle
  status: active
  projects: [egregore]
  started: 2026-02-10
  started_by: oz
  priority: 0
  completed: null
  ```
- **Sections**: The Question, Why This Matters, Threads (checklist), Contributions (table), Artifacts, Entry Points, Outcome

#### `wraps/` — Session Completion Logs
- **Written by**: `/wrap` command
- **Format**: `YYYY-MM/DD-author-topic.md`
- **Content**: What was accomplished, what needs continuation, energy/momentum notes

#### `artifacts/` — Long-Form Documents
- **Written by**: `/add` command
- **Format**: `YYYY-MM-DD-author-title.md`
- **Content**: Strategic writing, research syntheses, specifications, blog drafts

#### `projects/` — Project Reference
- **Written by**: Manual, `/project` updates
- **Content**: Domain, repo URL, description, active quests, key decisions, entry points

#### `meetings/` — Ingested Meetings
- **Written by**: `/meeting` command (from Granola transcripts)
- **Format**: `YYYY-MM-DD-topic.md`
- **Content**: Multi-lens analysis output (intelligence briefing format)

#### `research/` — User Interview Data
- **Written by**: `/ingest user-interview`
- **Subdirs**: `interviews/` (transcripts + analysis), `participants/` (participant profiles)

### Key Properties

- **Separate git repo**: Shared across team, stays on `main` branch (not develop)
- **Session sync**: `session-start.sh` runs `git -C memory fetch origin --quiet` + `git -C memory pull --ff-only` every session
- **Auto-merge**: Memory repo PRs (markdown-only) are auto-merged by `/save`
- **Index pattern**: Heavy use of `index.md` files to avoid context bloat — Claude reads indexes first, dives into specific files as needed
- **Filename convention**: Most files use `YYYY-MM-DD-author-topic.md` for chronological sorting and attribution
- **Planned**: `memory/index.yaml` will serve as a fast-lookup index for Claude (not yet implemented)

---

## 10. Infrastructure — Neo4j Instances

Two separate Neo4j instances. **Never cross them.**

| Instance | Purpose | Org scoping | Railway vars |
|----------|---------|-------------|--------------|
| CL instance | Curve Labs internal (our Egregore) | No org node, single-tenant | `NEO4J_URI`, `NEO4J_USER`, `NEO4J_PASSWORD` |
| Core instance | Client/customer Egregores | Org node per customer, multi-tenant | `NEO4J_CORE_URI`, `NEO4J_CORE_USER`, `NEO4J_CORE_PASSWORD` |

**OSS users hit neither.** When `EGREGORE_API_KEY` is missing, `graph.sh` returns empty JSON — no instance is contacted. All graph-dependent features degrade gracefully (no errors, just empty results).

**Registered free users** get routed to the Core instance under their org node when they run `/connect` or any graph-writing command. The API gateway (`api_url` in `egregore.json`) resolves the correct Neo4j instance from the org's config in Supabase.

**Hard rule**: Never write queries that assume a specific instance. Always go through `bin/graph.sh` which routes via the API gateway. The `$_org` parameter is auto-injected by the gateway for scoping.
