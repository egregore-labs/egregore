---
name: invite
description: Invite a GitHub user into this Egregore instance from Codex when the user invokes /invite or $invite, or asks to invite someone without exposing credentials.
---

# Egregore Invite

Native Codex Egregore skill. Invite a GitHub username to the configured repos
and, in connected mode, create the Egregore join link.

## Flow

1. Require a GitHub username. If missing, ask for it and stop.
2. Read mode and config from `egregore.json`. Never print secrets from `.env`.
3. Run credential-sensitive work in a single shell command that reads
   `GITHUB_TOKEN` and `EGREGORE_API_KEY` internally and only prints sanitized
   JSON.
4. Connected mode:
   - POST to the configured Egregore invite API with the GitHub username,
     org, repo, slug, API key, and GitHub token.
   - Parse the response and show invite status, memory access status, and the
     returned invite URL.
   - Best-effort graph record with `bin/graph.sh`.
   - If a contact channel exists, follow
     `.claude/context/notification-consent.md`: prepare a direct-message plan
     and show the exact organization, recipient, channel, and message in a
     separate Send / Edit / Cancel checkpoint. The invite request is not
     notification consent.
5. Local mode:
   - Use GitHub API collaborator endpoints for the core repo, memory repo, and
     managed repos.
   - Create or update `memory/people/{username}.md`.
   - Commit and push memory.
   - Show the join command using `npx -y create-egregore@latest join`.
6. If remote hosting is enabled, provision hosting best-effort in a detached
   command and include the status only when it succeeds.

## Rules

- Never expose tokens, request bodies containing tokens, or raw API JSON.
- Only org admins can complete the connected invite flow; report API denial
  clearly and give the manual GitHub access URL.
- Do not use Claude Code commands.
- Never fall back from an invite DM to a group or dispatch from detached work.
