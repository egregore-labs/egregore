---
name: notion-connect
description: "Use for 'connect notion', 'notion status', or 'disconnect notion' — connects the current agent runtime directly to Notion's official hosted MCP for search and fetch, or checks/revokes that connection."
---

Connect the current agent runtime directly to Notion's official hosted MCP.

Arguments: $ARGUMENTS (Optional: `status` or `revoke`)

## When to invoke

- "connect notion", "set up notion", "link notion" → run the connection flow
- "notion status", "is notion connected" → status
- "disconnect notion", "revoke notion" → revoke
- `/ingest notion` also enters this flow automatically when the MCP tools are
  missing. Users do not need to run this skill first.

## Product boundary

Notion provides the bridge. Egregore does not register a Notion OAuth app and
does not receive or store the user's Notion OAuth token. The current agent
runtime connects directly to `https://mcp.notion.com/mcp`; Notion owns the
login and consent screen, and the runtime stores its own authorization.

Say this before opening the login flow:

> Notion will connect directly to this agent. Egregore Labs does not receive
> your Notion login or token. The agent can see what your Notion account can
> see. Search and fetched content pass through this session; pages you approve
> are additionally saved as curated shared memory.

Do not claim that the MCP is read-only or limited to selected pages. Notion MCP
uses the signed-in user's permissions. Normal Egregore session capture may
include tool results the agent inspected. The `/ingest notion` review step is
the boundary for what becomes a curated Notion source in shared memory.

## Readiness check

First discover available tools using the runtime's tool registry:

- Claude Code: use ToolSearch with `notion`.
- Codex/OpenAI clients: search for Notion MCP tools. OpenAI may expose
  `notion-search` and `notion-fetch` as `search` and `fetch`.
- Other MCP-aware runtimes: inspect the loaded tools for the Notion server.

The connection is ready when both search and fetch are available. Prefer a
`notion-get-self`/`get-self` call for status when present; otherwise a small
search is enough to verify access.

## Setup

Use the path for the current runtime. These commands register Notion's official
remote MCP only; they do not install an Egregore connector.

### Claude Code

```bash
claude mcp get notion >/dev/null 2>&1 || \
  claude mcp add --transport http --scope project notion https://mcp.notion.com/mcp
claude mcp login notion
```

If the tools do not appear after login, say:

> Notion is connected. Restart this Claude Code session, then run `/ingest notion` again.

### Codex

The Egregore project config already declares the server. If it is absent in an
older installation:

```bash
codex mcp get notion >/dev/null 2>&1 || \
  codex mcp add notion --url https://mcp.notion.com/mcp
codex mcp login notion
```

If the tools do not appear after login, say:

> Notion is connected. Restart this Codex session, then run `$ingest notion` again.

### Pi

Pi does not provide MCP support. Do not fall back to the legacy REST connector.
Say:

> Notion MCP is not available in Pi yet. Open this Egregore in Claude Code or Codex to connect and import Notion pages.

Stop.

### Other MCP clients

Add `https://mcp.notion.com/mcp` as a Streamable HTTP server named `notion`,
then complete Notion's OAuth flow. If the client only loads new servers at
startup, ask the user to restart and return to `/ingest notion`.

## Continue into ingest

Once search and fetch are available, return directly to the calling
`/ingest notion` flow. When this skill was invoked on its own, close with:

> Connected. Run `/ingest notion` and tell me what you want to bring into memory.

## Status

Discover the Notion tools and call `notion-get-self`/`get-self` when available.
Report only connected workspace/user information returned by Notion. Do not
read `.egregore-state.json`; MCP authorization belongs to the runtime.

## Revoke

- Claude Code: `claude mcp logout notion`
- Codex: `codex mcp logout notion`
- Other clients: disconnect Notion from that client's MCP settings.

Confirm:

> Disconnected here. Pages already imported into Egregore memory remain until you remove them.

Telemetry, fire-and-forget:

```bash
bash bin/telemetry.sh emit "command" '{"command":"notion-connect","transport":"mcp"}' 2>/dev/null &
```
