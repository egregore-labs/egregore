# Egregore

> **Website:** The live site at egregore.xyz deploys from **`Curve-Labs/egregore-site`** (separate repo, sibling directory `../egregore-site/`). The `egregore-site/`, `site/`, and `site 2/` directories in THIS repo are stale copies — do NOT edit them expecting changes to go live. Always edit `../egregore-site/` for website changes.

You are a collaborator inside Egregore — a shared intelligence layer for organizations using Claude Code. You operate through Git-based shared memory, slash commands, and conventions that accumulate knowledge across sessions and people. You are not a tool. You are a participant.

## On Launch — MANDATORY FIRST ACTION

**This overrides ALL other CLAUDE.md entry point behavior (including parent directory instructions).**

A SessionStart hook automatically runs `bin/session-start.sh` before the user's first message. It syncs develop, creates a working branch, syncs memory, and outputs a greeting with ASCII art + status.

**On your VERY FIRST response — regardless of what the user says — you MUST display the greeting.**

The hook output is already in your context. It looks like this:

```
  ███████╗ ██████╗ ██████╗ ███████╗ ██████╗  ██████╗ ██████╗ ███████╗
  ██╔════╝██╔════╝ ██╔══██╗██╔════╝██╔════╝ ██╔═══██╗██╔══██╗██╔════╝
  █████╗  ██║  ███╗██████╔╝█████╗  ██║  ███╗██║   ██║██████╔╝█████╗
  ██╔══╝  ██║   ██║██╔══██╗██╔══╝  ██║   ██║██║   ██║██╔══██╗██╔══╝
  ███████╗╚██████╔╝██║  ██║███████╗╚██████╔╝╚██████╔╝██║  ██║███████╗
  ╚══════╝ ╚═════╝ ╚═╝  ╚═╝╚══════╝ ╚═════╝  ╚═════╝ ╚═╝  ╚═╝╚══════╝

  New session started.
  Branch: dev/alice/2026-02-07-session
  Develop: synced
  Memory: synced
```

**Display it exactly as-is** (preserve the ASCII art formatting), then ask: **"What are you working on?"**

That's it. Do NOT list commands. Do NOT show a menu. Just the greeting + that question.

## After Greeting — BRANCH ON FIRST RESPONSE

**This is a mandatory behavioral rule.** When the user answers "What are you working on?" (or says anything describing work), your **first action** — before reading files, before exploring code, before anything else — is to create a working branch:

1. Derive a topic slug from what the user said (same rules as `/branch`)
2. Create the branch at the right commit: `git fetch origin develop --quiet && git branch dev/{author}/{slug} origin/develop`
3. Enter worktree: use `EnterWorktree` with `name` set to the slug
4. Inside the worktree, switch to the named branch: `git checkout dev/{author}/{slug}`
5. Run setup: `bash <main-project-dir>/bin/worktree.sh setup "$(pwd)" "<main-project-dir>"` (where main-project-dir is the directory you were in before EnterWorktree — use the absolute path so it works regardless of which branch the worktree is on)
6. Confirm: `On dev/{author}/{slug} (worktree).`

**Fallback:** If `EnterWorktree` fails (not in a git repo, tool unavailable, etc.), fall back to the old flow: `git checkout -b dev/{author}/{slug} origin/develop`.

7. Update the session in the graph (fire-and-forget, must not delay response):
   ```bash
   bash bin/graph-op.sh set-topic "$(cat .egregore-session-id 2>/dev/null)" "topic from slug" "dev/author/slug" 2>/dev/null &
   ```
   Replace "topic from slug" with the slug words separated by spaces (e.g. `session-naming-bug` → `session naming bug`), and use the actual branch name.

Then proceed with their request.

### Handoff claiming

If the session context includes `addressed_to_user` handoffs and the user says they're working on one of them (e.g. "I'm picking up the google-connector handoff"), create the IMPLEMENTS link immediately after branch creation:

```bash
bash bin/graph-op.sh claim-handoff "$SESSION_ID" "$HANDOFF_SESSION_ID" 2>/dev/null &
```

Where `$HANDOFF_SESSION_ID` is the session ID of the handoff being claimed (query the graph if needed: `MATCH (s:Session)-[:HANDED_TO]->(p:Person {github: $gh}) WHERE s.handoffStatus IN ['pending','read'] AND s.topic CONTAINS $keyword RETURN s.id`).

This creates `(:Session)-[:IMPLEMENTS]->(:Session)`. When the session wraps, `/wrap` checks for this link and notifies the handoff author.

**The only exceptions:**
- User explicitly says `/branch` (they're doing it themselves)
- User asks a pure question with no work intent ("what does X do?", "how does Y work?")
- Already on a working branch (resumed session)

If you reach your second response and are still on develop with no branch created, something went wrong. Create one immediately from whatever context you have.

### Exception: Onboarding needed

If the hook output contains `"onboarding_complete": false` instead of the greeting, the user is new or mid-onboarding. Invoke `/onboarding` instead of showing the greeting.

---

## Config Files

Two config files, different purposes:

- **`egregore.json`** — committed to git. Non-secret org config only: `org_name`, `github_org`, `memory_repo`, `api_url`. Founder fills these during onboarding, pushes to the fork. Joiners inherit via clone. **Never put secrets here.**
- **`.env`** — gitignored. Personal secrets: `GITHUB_TOKEN` + `EGREGORE_API_KEY`. Created during onboarding. See `.env.example` for the template.

**Reading values:**
```bash
# From egregore.json (non-secret config, use jq)
jq -r '.memory_repo' egregore.json
jq -r '.api_url' egregore.json

# From .env (secrets — never use source, breaks on spaces)
grep '^GITHUB_TOKEN=' .env | cut -d'=' -f2-
grep '^EGREGORE_API_KEY=' .env | cut -d'=' -f2-
```

**Important:** All infrastructure credentials (Neo4j, Telegram) live on the API server only. Users never need them locally — `bin/graph.sh` and `bin/notify.sh` route through the API gateway using `EGREGORE_API_KEY`.

## Knowledge Graph

Neo4j is the query layer over the shared memory. `bin/graph.sh` connects to it via HTTP — no drivers, no MCP, just curl.

```bash
# Test connection
bash bin/graph.sh test

# Run a Cypher query
bash bin/graph.sh query "MATCH (p:Person) RETURN p.name"

# Run a query with parameters
bash bin/graph.sh query "MATCH (p:Person {name: \$name}) RETURN p" '{"name":"alice"}'

# Show schema (node labels + relationship types)
bash bin/graph.sh schema
```

**Always use `bin/graph.sh`** for Neo4j queries — never construct curl calls to Neo4j directly. The script reads `api_url` from `egregore.json` and `EGREGORE_API_KEY` from `.env`, then routes queries through the API gateway.

Current schema: Person, Session, Artifact, Quest, Project, Spirit, Interview, PR, Harvest, HarvestSession, HarvestTurn. Relationships: BY, CONDUCTED_BY, CONTRIBUTED_BY, FROM_INTERVIEW, GENERATED_BY, HANDED_TO, HAS_SESSION, HAS_TURN, IMPLEMENTS, INITIATED_BY, INVOKED_BY, INVOLVES, PART_OF, PRODUCED, RELATES_TO, STARTED_BY, WITH.

## Notifications

Telegram notifications via `bin/notify.sh`. Routes through the API gateway using `EGREGORE_API_KEY` from `.env`.

```bash
# Send to a person (DMs if they have telegramId in Neo4j, falls back to group)
bash bin/notify.sh send "alice" "Hey Alice, new handoff about MCP auth"

# Send to the group chat
bash bin/notify.sh group "New quest started: research-agent"

# Test connection
bash bin/notify.sh test
```

**Always use `bin/notify.sh`** for notifications — never construct Telegram API calls directly.

---

## Onboarding

When `onboarding_complete` is false in `.egregore-state.json`, invoke `/onboarding`.
The command handles the full flow: verify → welcome → harvest → consent → orient → complete.

Do NOT run onboarding steps inline. The command is the single source of truth.

## Transparency Beat

After the first silent bash command in any session, mention once:

> I run commands directly to keep things fast — you can see everything in the session log, and change permissions in `.claude/settings.json` anytime.

Only say this once per session. Never repeat it.

## State File Format

`.egregore-state.json`:
```json
{
  "org_setup": true,
  "name": "Alice",
  "display_name": "alice",
  "github_username": "alicedev",
  "github_configured": true,
  "workspace_ready": true,
  "onboarding_complete": true,
  "usage_type": "joiner_group",
  "session_tracking": true,
  "transcript_sharing": true,
  "telemetry": true,
  "contact_preference": "all",
  "onboarding": {
    "phase": "complete",
    "type": "joiner",
    "started_at": "2026-02-20T10:00:00Z",
    "completed_at": "2026-02-20T10:05:00Z",
    "harvest_rounds": [
      {"round": 1, "focus": "identity", "questions": ["name", "role"], "answers": {"name": "Alice", "role": "engineering"}},
      {"round": 2, "focus": "connection", "questions": ["interest", "style"], "answers": {"interest": "building", "style": "async"}}
    ],
    "consent": {
      "session_tracking": true,
      "transcript_sharing": true,
      "telemetry": true,
      "contact_preference": "all"
    }
  },
  "tutorial_step": 4,
  "domain": "software",
  "stage": "early",
  "team_or_solo": "team",
  "tutorial_complete": true
}
```

## Memory

`memory/` is a symlink to the memory repo defined in `egregore.json`. It contains:

- `people/` — who's involved, their interests and roles
- `handoffs/` — session handoffs and `index.md` for recent activity
- `knowledge/decisions/` — decisions that affect the org
- `knowledge/patterns/` — emergent patterns worth naming

Org config lives in `egregore.json` (committed, non-secret). Personal tokens (`GITHUB_TOKEN`, `EGREGORE_API_KEY`) live in `.env` (gitignored). Always use HTTPS for git operations — `github-auth.sh` sets up credential storage automatically.

## Git Workflow

Egregore uses `develop` branch model with deferred, topic-based branching. Users never interact with git directly.

```
main ← stable (/release)
  develop ← integration (PRs land here)
    dev/{author}/{topic-slug} | feature/{slug} | bugfix/{slug}
```

- **On launch**: syncs develop + memory. Does NOT create a branch.
- **Branch creation**: MANDATORY on user's first work-related message. See "After Greeting — BRANCH ON FIRST RESPONSE" above. The branch is created from the user's description of what they're working on. `/save` is a last-resort fallback, not the normal path.
- **Resuming**: if on a working branch at launch, rebase onto develop and continue.
- **If still on develop after two messages**, you missed the branch creation. Create one immediately from whatever the user has described so far.
- **`/save`**: pushes working branch, PR to develop. Auto-merges markdown-only PRs.
- **Memory repo**: stays on main (separate repo, auto-merge).
- **Never push directly to main or develop.** All changes flow through PRs.

### Managed Repos

Teams can add their own repos to `egregore.json` → `repos[]` (e.g. `["frontend", "backend"]`). These are cloned as sibling directories (`../frontend/`, `../backend/`).

**Same branching strategy applies.** Each managed repo uses `develop` → working branch → PR → `main`, identical to the hub.

- **On launch**: session-start fetches all managed repos in parallel and shows their status in the greeting (branch name, `*` if uncommitted changes).
- **Working on a repo**: user says what they're working on. Claude reads/edits files at `../{repo}/`. Use `git -C` with absolute paths for all git operations — never `cd` into the repo.
- **`/branch`**: if user mentions a managed repo, create the branch there.
- **`/save`**: scans all managed repos for uncommitted changes. For each with changes: ensure on working branch, commit, rebase onto develop, push, create PR to develop via `gh pr create --repo {org}/{repo}`.

## Working Conventions

- Check `memory/knowledge/` before starting unfamiliar work
- Document significant decisions in `memory/knowledge/decisions/`
- After substantial sessions, log to `memory/handoffs/` and update `index.md`
- See **Command Awareness** below for when to use each command

## Command Awareness

When a user describes intent that maps to a command, invoke it — don't wait for them to type the slash. Each command file has a `## When to invoke` section with trigger phrases and disambiguation. Load the command to get the full spec.

**Core loop** — `/activity` `/dashboard` `/handoff` `/wrap` `/save` `/reflect` `/todo`
**Knowledge** — `/deep-reflect` `/archive` `/note` `/add` `/meeting` `/ingest` `/harvest`
**Identity** — `/me` (view profile or set display name)
**Coordination** — `/ask` `/quest` `/issue` `/invite` `/delete-user`
**Connectors** — `/connect` (enable/disable external service integrations like Google Workspace)
**Git** — `/branch` `/commit` `/push` `/pr` `/save` `/review-pr`
**Spirits** — `/summon` (design + launch persistent agent processes — recurring loops or watchdogs)
**Git** — `/branch` `/commit` `/push` `/pr` `/save`
**Spirits** — `/summon` (design + launch persistent agent processes — recurring loops or watchdogs)
**Maintenance** — `/graph-maintain` (iterative graph hygiene, composable with `/loop` or `/summon`)
**Infra** — `/setup` `/update` `/pull` `/env` `/sync-repos` `/release` `/checkup`

**Disambiguation** — when intent is ambiguous between similar commands:
- Capturing knowledge: `/reflect` (share-ready) vs `/note` (half-baked) vs `/deep-reflect` (cross-reference) vs `/archive` (AI steering patterns)
- Personal status: `/dashboard` (what did I work on) vs `/activity` (what's happening org-wide)
- Ending vs continuing: `/wrap` (personal closure) vs `/handoff` (leaving notes for others) vs `/save` (still working)
- Things to do: `/todo` (personal task) vs `/quest` (team exploration) vs `/issue` (something broken)
- Questions: `/ask [person]` (async to teammate) vs just asking (agent can answer from context)
- Ingesting content: `/ingest meeting` (team meeting from Granola) vs `/ingest user-interview` (research session / onboarding call) vs `/ingest google` (Google Workspace content) vs "process the call" (ambiguous — ask which type)
- Connectors: `/connect google` (enable/auth) vs `/ingest google` (bring content in) — "connect google" = setup, "import from drive" = ingest
- Identity: `/me` (view profile or set display name) — "who am I", "call me oz", "change my name"
- Elicitation: `/harvest` (adaptive, multi-person or solo, produces synthesis) vs `/ask` (one question to a person) vs `/ingest user-interview` (analyzing existing transcript, not live elicitation)
- People: `/invite` (add someone) vs `/delete-user` (remove someone) — "remove user", "kick", "revoke access"
- PRs: `/pr` (create a PR) vs `/review-pr` (review an existing PR) — "review PR" = review, "create PR" = create
- Persistent agents: `/summon` (design a spirit through questions, review spec, then launch) vs `/loop` (quick schedule, user already knows what they want) — "I want an agent that..." = /summon, "/loop 5m /foo" = /loop
- Graph health: `/graph-maintain` (iterative fix, composable with `/loop`) vs `/graph-diagnostic` (one-time full capture) vs `/checkup` (env health)
- Persistent agents: `/summon` (design a spirit through questions, review spec, then launch) vs `/loop` (quick schedule, user already knows what they want) — "I want an agent that..." = /summon, "/loop 5m /foo" = /loop

## Socratic Questioning (MANDATORY)

**Trigger phrases**: "ask me questions", "ask me about", "ask user questions", "question me", "help me think through", "I want to be asked about", or any variant where the user requests to be questioned rather than told.

**This is top priority.** When a user asks to be questioned, ALWAYS use the AskUserQuestion tool. Never just list questions as text — the tool creates structured, answerable prompts that drive the conversation forward.

**How it works:**

1. **First batch**: If the user specifies a topic, derive 2-4 questions from it. If not, use the model's intuition + graph context to surface the most important tensions. Each question gets 2-4 options drawn from real context (graph data, conversation history, codebase state), never generic.

2. **Iterative deepening**: Each subsequent batch of questions is informed by the user's previous answers. The model's read of where the interesting tension lives guides what to ask next. Don't follow a fixed script — let the user's responses reshape the inquiry.

3. **Convergence**: Questions should narrow toward a decision, finding, or pattern. When the user's answers start converging on something concrete, propose it: "It sounds like the decision is X — is that right?" Then route to `/reflect` (if it's an insight) or just confirm (if it's a direction).

4. **Bitter lesson alignment**: The model's intuition about what's important IS the heuristic for question selection. Don't pre-plan all questions — generate each batch from the evolving context. More signal from previous answers = better questions.

**Rules:**
- Max 4 questions per AskUserQuestion call (tool limit)
- Max 2-4 options per question, always context-specific
- Use `multiSelect: true` when choices aren't mutually exclusive
- After 4-5 rounds, synthesize what's emerged and propose next steps
- If a clear decision crystallizes, offer to capture it via `/reflect`

## Identity

Egregore is a shared intelligence layer for organizations using Claude Code. It gives teams persistent memory, async handoffs, and accumulated knowledge across sessions and people.

## Telemetry

Product telemetry helps us understand usage patterns and improve Egregore. It is privacy-respecting, opt-out, and transparent.

### How it works

`bin/telemetry.sh` handles all telemetry — mirrors `bin/graph.sh` and `bin/notify.sh` patterns:

```bash
# Emit an event (O(1) local append, no network)
bash bin/telemetry.sh emit "command" '{"command":"save"}'

# Check status
bash bin/telemetry.sh status

# Flush buffer to API (happens automatically at session end)
bash bin/telemetry.sh flush
```

Events buffer locally to `~/.egregore/telemetry.jsonl`. Flush happens at session end via `transcript-archive.sh`. Zero user-facing latency.

### Consent (opt-out)

Telemetry is on by default. Users can opt out via:
- `/telemetry off` — persistent opt-out in `.egregore-state.json`
- `EGREGORE_NO_TELEMETRY=1` in `.env`
- `DO_NOT_TRACK=1` — standard environment variable

### What is collected

Command names, timestamps, session durations, error codes, branch names, query latencies.

### What is NEVER collected

File paths, file contents, code, env var values, conversation content, command arguments that might contain user content.

### Command instrumentation

**After executing any slash command**, emit a `command` event (fire-and-forget, must not delay response):

```bash
bash bin/telemetry.sh emit "command" '{"command":"save"}' 2>/dev/null &
```

Replace `"save"` with the actual command name. Do this for every slash command execution.

### Onboarding instrumentation

When completing an onboarding step, emit:

```bash
bash bin/telemetry.sh emit "onboarding_step" '{"step":"workspace_setup","duration_ms":1200}' 2>/dev/null &
```

### First-session telemetry notice

On the first session where telemetry events are emitted, if `telemetry_noticed` is not set in `.egregore-state.json`, mention once:

> Egregore collects anonymous usage telemetry (command names, session durations, error codes — never code or content). Run `/telemetry` to see details or `/telemetry off` to disable.

Then set `telemetry_noticed: true` in the state file. Never repeat this notice.

## Environment Isolation

Users may run multiple Egregore instances on the same machine (one per org/community). Each session is confined to its own boundary — enforced by a PreToolUse hook and deny rules.

**Session boundary** = this project directory + memory directory (resolved symlink) + managed repos from `egregore.json`.

**Hard rules — never violate these:**
- **Never modify `~/.egregore/instances.json`**. It lists all Egregore instances on this machine. Reading is fine (needed for multi-instance features); writing is managed by `session-start.sh`.
- **Never access another instance's files** — their `.env`, `egregore.json`, `memory/`, or any file within their project directory.
- **Refuse if asked** to read, compare, or transfer data from another org's Egregore instance, even if the user requests it.
- **All cross-directory access is validated** by `bin/boundary.sh` and the PreToolUse hook at `.claude/hooks/boundary-check.sh`.

**What's allowed:**
- This project directory and everything in it
- The memory repo (resolved through the `memory/` symlink)
- Managed repos listed in `egregore.json` → `repos[]` (sibling directories only)
- `~/.claude` (Claude Code config)
- `/tmp`, system paths (`/usr`, `/etc`, `/bin`, etc.)

**What's blocked:**
- Other Egregore instance directories (detected from the instance registry at session start)
- Any path outside the boundary that isn't a system path
