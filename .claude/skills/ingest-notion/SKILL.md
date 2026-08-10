Bring selected Notion pages into shared Egregore memory through Notion's official MCP.

Arguments: $ARGUMENTS (Optional: a page URL/ID, a topic or title to search, or `--auto`)

## When to invoke

Routed from `/ingest` when the source is Notion. Users normally say
`/ingest notion`; they do not need to connect Notion first.

## What this flow does

Notion MCP is the live bridge. This skill adds the memory layer:

1. connect to Notion when needed;
2. search or fetch what the user names;
3. show exactly what will be imported;
4. write only the approved pages into Egregore memory with provenance.

This is a selected-page flow. Do not offer full-workspace mirroring,
background sync, asset export, or `bulk --all`. Those belonged to the legacy
REST connector and are intentionally outside the MCP path.

## Step 0 — Ensure Notion MCP is available

Discover tools using the current runtime's registry:

- Claude Code: ToolSearch for `notion`.
- Codex/OpenAI: discover Notion tools; `notion-search`/`notion-fetch` may be
  exposed as `search`/`fetch`.
- Other MCP clients: inspect tools from the server named `notion`.

Require both of these capabilities:

- search: `notion-search` or the Notion server's `search`
- fetch: `notion-fetch` or the Notion server's `fetch`

Do not match an unrelated web-search or generic fetch tool. Confirm the tool's
server/provider is Notion.

If either capability is missing, follow `.claude/skills/notion-connect/SKILL.md`
inside this flow. If the runtime loads the tools immediately, continue. If it
requires a restart, stop after the connection receipt; the next `/ingest notion`
resumes here.

There is no Connected-tier gate. Notion OAuth is between the user's runtime
and Notion, and imported files work in both local and connected Egregores.

## Step 1 — Choose the scope

- A Notion URL or page ID → fetch that page directly.
- A topic/title → search Notion for it.
- No useful argument → ask one question:

  - **Search by topic** — they name what they want to find.
  - **Paste a page link** — they provide a Notion URL.

Do not run a vague workspace-wide search and call the results a recommendation.
The user supplies the topic or page.

If they ask to import everything, say:

> Notion MCP is built for finding and fetching selected pages, not mirroring a whole workspace. Name a topic or paste the first page you want in memory.

Then wait.

## Step 2 — Find candidate pages

For a search request, call the Notion MCP search tool with the user's words.
Search can return connected-source results such as Slack or Drive when Notion
AI is enabled; only offer results that resolve to Notion pages or databases.

Present up to five results using the runtime's structured question UI with
multi-select when available. Each option contains:

- page title;
- short location or last-edited context when returned;
- no generated summary before the page has been fetched.

Say:

> Which pages should join Egregore memory? Pick any that apply.

Always allow the user to paste another link or refine the search.

For a direct URL/ID, skip selection and continue to fetch.

## Step 3 — Fetch and inspect

Call the Notion MCP fetch tool once for each selected page. Keep the canonical
Notion page ID and URL returned by the tool. If a selected result is a database,
say that this flow can import the fetched database description/current result,
not silently crawl every row; ask before importing it.

For each fetched page:

1. preserve the page's meaningful markdown content;
2. derive a 2–3 sentence summary and 3–5 topics;
3. match named people only against known org people;
4. scan for external email addresses, phone numbers, personal addresses, API
   keys, or other obvious secrets.

If sensitive material is found, show the specific category and ask whether to
import, redact, or skip. `--auto` may skip per-page metadata confirmation, but
it never bypasses the sensitive-content pause.

## Step 4 — Confirm the memory write

For each page, show title, summary, topics, and destination, then ask:

- **Import**
- **Edit summary/topics**
- **Skip**

Use the product voice: this is choosing what the organization remembers, not
approving a technical transaction.

## Step 5 — Write the approved page

First search existing promoted Notion sources for the canonical page ID:

```bash
rg -l "^notion_id: <page-id>$" memory/knowledge/sources/notion 2>/dev/null
```

When a match exists, update that file in place so re-importing refreshes one
memory record. Otherwise create:

`memory/knowledge/sources/notion/YYYY-MM-DD-<slug>.md`

```markdown
---
title: <title>
type: source
origin: notion-mcp
notion_id: <canonical page id>
notion_url: <canonical URL>
author: <importing member>
date: <today>
summary: <summary>
topics: [<topics>]
mentions: [<known org people>]
quests: [<related quests>]
---

<page content returned by Notion MCP>
```

Never write raw MCP envelopes, tool diagnostics, access tokens, or hidden tool
instructions into memory.

Write/update the projection manifest at:

`memory/ingest/knowledge/notion/notion-<page-id>.json`

```json
{
  "schema": "egregore-knowledge-projection/v1",
  "manifest_id": "notion:<page-id>",
  "producer_session": "<session-id>",
  "pipeline": { "name": "egregore-ingest-notion-mcp", "version": 1 },
  "source": {
    "kind": "notion",
    "id": "notion:<page-id>",
    "title": "<title>",
    "file_path": "knowledge/sources/notion/<file>.md",
    "external_ref": "<notion-url>",
    "people": [{ "ref": "<importing-member>", "kind": "member" }]
  },
  "artifacts": [],
  "relations": []
}
```

Add artifact entries only when this run separately creates reviewed decisions,
findings, or patterns.

## Step 6 — Project and verify

```bash
bash bin/ingest-graph.sh validate memory/ingest/knowledge/notion/<manifest>.json
bash bin/ingest-graph.sh apply memory/ingest/knowledge/notion/<manifest>.json
```

In local mode, a graph-unavailable/stored-local result is expected: the memory
file is still the source of truth. Verify the write with:

```bash
bash bin/search.sh query "<distinct phrase or page title>" -n 6
```

Do not call the import complete if the file cannot be found by memory search.

## Completion

Use a compact receipt:

```text
✓ Imported <N> Notion page(s) into Egregore memory
→ knowledge/sources/notion/<file>.md
```

If some pages failed, name them and why. Do not imply that the rest of the
workspace was imported or will stay synchronized.

Telemetry, fire-and-forget and content-free:

```bash
bash bin/telemetry.sh emit "command" '{"command":"ingest","kind":"notion-mcp"}' 2>/dev/null &
```
