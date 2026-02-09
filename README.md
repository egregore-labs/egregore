```
  ███████╗ ██████╗ ██████╗ ███████╗ ██████╗  ██████╗ ██████╗ ███████╗
  ██╔════╝██╔════╝ ██╔══██╗██╔════╝██╔════╝ ██╔═══██╗██╔══██╗██╔════╝
  █████╗  ██║  ███╗██████╔╝█████╗  ██║  ███╗██║   ██║██████╔╝█████╗
  ██╔══╝  ██║   ██║██╔══██╗██╔══╝  ██║   ██║██║   ██║██╔══██╗██╔══╝
  ███████╗╚██████╔╝██║  ██║███████╗╚██████╔╝╚██████╔╝██║  ██║███████╗
  ╚══════╝ ╚═════╝ ╚═╝  ╚═╝╚══════╝ ╚═════╝  ╚═════╝ ╚═╝  ╚═╝╚══════╝
```

A shared intelligence layer for organizations using Claude Code. Persistent memory, async handoffs, and accumulated knowledge across sessions and people.

## Prerequisites

- [git](https://git-scm.com)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) — `npm install -g @anthropic-ai/claude-code`

## Install

### From the website (recommended)

Visit [egregore-core.netlify.app](https://egregore-core.netlify.app), sign in with GitHub, pick your org and repos, then run the one-liner it gives you:

```bash
npx create-egregore --token st_xxx
```

Or without Node.js:

```bash
curl -fsSL https://egregore-core.netlify.app/api/org/install/st_xxx | bash
```

### From an invite

Got an invite link? Open it, sign in with GitHub, and you'll get the same one-liner.

### Interactive (no website)

```bash
npx create-egregore
```

Walks you through GitHub auth, org selection, and repo setup in the terminal.

## What happens

1. **Authenticate** — Sign in with GitHub (OAuth, no tokens to copy)
2. **Pick your org** — Choose a GitHub org or personal account
3. **Pick repos** — Select which org repos Egregore should manage (or skip for collaboration-only)
4. **Generate** — Creates your org's egregore instance, shared memory repo, and knowledge graph
5. **Connect Telegram** — Optionally add the bot to a group for async notifications

Each org can have multiple egregore instances with separate graphs and Telegram groups.

## After setup

From any terminal:

```bash
egregore
```

This syncs everything, puts you on a fresh working branch, and shows you where you are.

### Commands

| Command | What it does |
|---------|-------------|
| `/activity` | See what's happening across your org |
| `/handoff` | Leave notes for others (or future you) |
| `/invite` | Invite someone to your org |
| `/quest` | Start or contribute to an exploration |
| `/ask` | AI-generated questions, routed to self or others |
| `/save` | Commit and push your contributions |

## Invite others

```
/invite <github-username>
```

Sends a GitHub org invitation and generates an invite link. They click, authenticate, and get a one-liner to install.

## How it works

Egregore gives your team a shared brain that persists across Claude Code sessions:

- **Memory** — Git-based shared knowledge repo (conversations, decisions, patterns)
- **Knowledge graph** — Neo4j for querying across sessions, people, and artifacts
- **Notifications** — Telegram for async handoffs and questions
- **Commands** — Slash commands for common workflows, no git knowledge needed
- **Repos** — Managed repos are cloned alongside your instance for shared context

Built by [Curve Labs](https://curvelabs.eu).
