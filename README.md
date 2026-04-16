```
  ███████╗ ██████╗ ██████╗ ███████╗ ██████╗  ██████╗ ██████╗ ███████╗
  ██╔════╝██╔════╝ ██╔══██╗██╔════╝██╔════╝ ██╔═══██╗██╔══██╗██╔════╝
  █████╗  ██║  ███╗██████╔╝█████╗  ██║  ███╗██║   ██║██████╔╝█████╗
  ██╔══╝  ██║   ██║██╔══██╗██╔══╝  ██║   ██║██║   ██║██╔══██╗██╔══╝
  ███████╗╚██████╔╝██║  ██║███████╗╚██████╔╝╚██████╔╝██║  ██║███████╗
  ╚══════╝ ╚═════╝ ╚═╝  ╚═╝╚══════╝ ╚═════╝  ╚═════╝ ╚═╝  ╚═╝╚══════╝
```

A shared intelligence layer for teams using Claude Code. Persistent memory, async handoffs, and accumulated knowledge across sessions and people.

## Prerequisites

- [git](https://git-scm.com)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) — `npm install -g @anthropic-ai/claude-code`

## Install

Two paths — both end up with the same local workspace; only the credential source differs. Pick based on your org's policy.

### Option 1 — `npx` (simplest, ~30 seconds)

```bash
npx create-egregore@latest --open
```

Walks you through GitHub auth, picks the owner + project name, creates your Egregore + memory repos, clones everything locally, and installs a shell alias.

**What the Egregore GitHub App does:** it requests per-repo access to only the repos you select — your Egregore instance, its memory repo, and any managed project repos. It uses standard GitHub APIs for repo creation, clone, push, and collaborator invites; it does not read code content. You pick exactly which repos it can touch; revoke anytime at *GitHub Settings → Applications*. The App exists so you get clean per-repo scoping without handing over a broad personal access token.

### Option 2 — `gh` CLI (for orgs that block third-party Apps)

Some organizations — especially regulated ones — block third-party GitHub Apps by policy. For that case:

```bash
# 1. One-time: install + auth the GitHub CLI
brew install gh          # macOS — or see https://cli.github.com
gh auth login            # first-party device flow

# 2. Grab the installer (inspect it before running)
curl -sLO https://raw.githubusercontent.com/egregore-labs/egregore/main/bin/init-gh.sh
less init-gh.sh          # optional — read what it will do

# 3. Run it
bash init-gh.sh
```

`gh` is GitHub's own first-party CLI. Its token is minted by GitHub for you, with no third party involved. The installer does only local-side work (`gh repo create` + `gh repo clone` + shell) — every command is visible in [bin/init-gh.sh](./bin/init-gh.sh).

Full step-by-step with every prompt explained: [INSTALL-GH.md](./INSTALL-GH.md).

### Both paths at a glance

| | Option 1 (`npx`) | Option 2 (`gh`) |
|---|---|---|
| Credential source | Egregore GitHub App | `gh auth login` (first-party) |
| Works on orgs that block third-party Apps | Usually no | Usually yes |
| Result on your machine | Identical | Identical |
| Teammate invitation flow | Same | Same |

Everything is MIT-licensed. Every install script is in `bin/` and every hook is in `.claude/hooks/` — read them before you run them.

## Start

Setup adds a shell command to your profile. Open a new terminal and type:

```bash
egregore
```

This opens Claude Code in your Egregore directory, syncs memory, and picks up where you left off.

## Commands

| Command | What it does |
|---------|-------------|
| `/reflect` | Capture a decision, pattern, or insight |
| `/handoff` | Leave notes for others (or future you) |
| `/quest` | Start or contribute to an exploration |
| `/ask` | Ask questions, routed to self or others |
| `/activity` | See what's happening across your team |
| `/dashboard` | Your personal status and recent work |
| `/todo` | Manage personal tasks |
| `/save` | Commit and push your contributions |
| `/invite` | Invite someone to your Egregore |

## Invite others

```
/invite <github-username>
```

Adds them as a collaborator on GitHub. They accept by running either path (whichever their org allows):

```bash
# npx path
npx create-egregore@latest join <your-owner>/<egregore-repo>

# or gh path — no third-party App
curl -sLO https://raw.githubusercontent.com/egregore-labs/egregore/main/bin/join-gh.sh
bash join-gh.sh <your-owner>/<egregore-repo>
```

Both auto-accept pending invitations, clone core + memory + managed repos as siblings, and run `/onboarding` on first session.

## How it works

Egregore gives your team a shared brain that persists across Claude Code sessions:

- **Memory** — Git-based shared knowledge repo (decisions, patterns, handoffs)
- **Commands** — Slash commands for common workflows, no git knowledge needed
- **Repos** — Managed repos are cloned alongside your instance for shared context
- **Sessions** — Each person works independently; knowledge flows through handoffs and memory

Everything runs locally. No servers, no accounts, no API keys.

## What runs on your machine

Egregore uses [Claude Code hooks](https://docs.anthropic.com/en/docs/claude-code/hooks) to automate session management. These run automatically when you start Claude Code in an Egregore directory:

| Hook | Purpose |
|------|---------|
| **SessionStart** | Syncs memory, resolves identity, renders greeting |
| **PreToolUse** | Boundary isolation (prevents accessing other projects) + branch protection |
| **PostToolUse** | Activity tracking (local file, not sent anywhere) |
| **WorktreeCreate/Remove** | Isolated git worktrees per session |
| **PreCompact** | Saves context before memory compression |
| **Stop** | Reminds you to save unsaved work |
| **SessionEnd** | Archives session transcript (local mode: local only, opt-in to share) |

All hooks are shell scripts in `bin/` and `.claude/hooks/` — read them directly.

## Telemetry

Egregore collects anonymous usage data (command names and timestamps only — never code, file contents, or conversation). Opt out anytime:

```bash
# In your .env
EGREGORE_NO_TELEMETRY=1

# Or the standard flag
DO_NOT_TRACK=1
```

Full details: `.claude/context/telemetry.md`

## Managed hosting

Want the knowledge graph, real-time dashboard, and Telegram notifications? Visit [egregore.xyz](https://egregore.xyz).
