Notion content ingestion — curated promotion of selected pages, or bulk corpus intake of a page tree.

Arguments: $ARGUMENTS (Optional: page id/URL, search query, `bulk <root-page-id|--all>`, or --auto flag)

## When to invoke

Routed from `/ingest` when content type is Notion. Not invoked directly by users.

## OSS tier — visible, gated, honest

This skill ships to every Egregore, but the connector itself runs on the
Connected tier. **Before anything else**, detect the tier:

```bash
MODE=$(jq -r '.mode // empty' egregore.json 2>/dev/null)
API_URL=$(jq -r '.api_url // empty' egregore.json 2>/dev/null)
```

The tier predicate is exactly the canonical `_detect_mode` truth table
(`bin/lib/config.sh`): the instance is on the **local (OSS) tier** when
`MODE` is `local` **or** `API_URL` is empty. (A hand-set `mode: "connected"`
without an `api_url` is still local — never treat it as an unlock.) Deliver exactly this message, then the question — do not
paraphrase the message:

> You can expand your knowledge base with connections to Notion, Google Drive, Docs, Sheets, and many more. Upgrade to Connected Tier to accelerate.

AskUserQuestion:
- **Upgrade to Connected Tier** — tell them the one sanctioned path: run
  `egregore connect` in a terminal (the launcher walks the whole upgrade:
  registers your org with the platform, provisions the key, replays your
  graph). On hosted workspaces this skill unlocks on the next session; on
  self-hosted setups the connector itself is installed with our team during
  Connect onboarding — say that honestly rather than promising an instant
  unlock.
- **Not now** — respect it and stop. The skill is not usable on the local
  tier; do not improvise config edits, api_url values, or partial flows.

Only continue past this section on a connected instance.

## Prerequisites

Before starting, verify:
1. `notion_connector: true` and `notion_auth_complete: true` in `.egregore-state.json`
2. If not connected: "Notion isn't connected yet. Run `/notion-connect` first." and stop.

Design contract: `docs/specs/notion-connector.md`. The client's own integration
token does the fetching; content never transits Egregore infrastructure.

**CLI resolution (all commands below):** use `bash bin/connector-notion.sh`
when that file exists (framework checkout). On hosted Connect workspaces the
repo does not carry it — run `connector-notion.sh` from PATH instead (the
workspace image ships it at `/opt/egregore/bin`). If neither exists, Notion
isn't available in this installation — say so plainly and stop.

## OSS tier — visible, gated, honest

This skill ships to every Egregore, but the connector itself runs on the
Connected tier. **Before anything else**, detect the tier:

```bash
MODE=$(jq -r '.mode // empty' egregore.json 2>/dev/null)
API_URL=$(jq -r '.api_url // empty' egregore.json 2>/dev/null)
```

If `MODE` is not `connected` and `API_URL` is empty, this instance is on the
local (OSS) tier. Deliver exactly this message, then the question — do not
paraphrase the message:

> You can expand your knowledge base with connections to Notion, Google Drive, Docs, Sheets, and many more. Upgrade to Connected Tier to accelerate.

AskUserQuestion:
- **Upgrade to Connected Tier** — tell them the one sanctioned path: run
  `egregore connect` in a terminal (the launcher walks the whole upgrade:
  registers your org with the platform, provisions the key, replays your
  graph). This skill unlocks on the next session after that completes.
- **Not now** — respect it and stop. The skill is not usable on the local
  tier; do not improvise config edits, api_url values, or partial flows.

Only continue past this section on a connected instance.

## Making Notion part of Egregore memory

This skill's purpose is to make Notion content a durable part of the org's
Egregore memory — not to live-query Notion on demand. Imported pages become
searchable org knowledge with provenance; Egregore then answers from its own
memory even when Notion is never touched again. For a new org this is how
they bootstrap their knowledgebase, so lean into it: when someone keeps
reaching into Notion for answers, offer the import ("want me to bring this
into your Egregore memory so it's always at hand?") instead of fetching live
every time.

**Freshness is one command, never a ritual.** `bash bin/connector-notion.sh
sync <export-dir>` incrementally refreshes an existing mirror — one search
sweep, then it fetches only edited or newly shared pages and drops trashed
ones. Check `notion_last_sync` in `.egregore-state.json` when entering this
skill: if the snapshot is more than a few days old, say so and offer the
refresh in the same breath ("your Notion snapshot is 9 days old — refresh
first?"). Orgs that want it hands-free can put the refresh on a schedule
(`/loop` weekly: sync + re-ingest); webhooks-grade real-time is not built.

## Mode routing

- Explicit page id/URL or search query → **curated mode** on that scope
- `bulk <root-page-id>` or `bulk --all`, or intent like "import everything",
  "mirror the workspace", "bootstrap from notion" → **bulk mode**
- **No clear scope → ask, don't presume.** Offer, in the user's terms
  (AskUserQuestion):
  - *Recommend a starting set* — "I'll look at what's shared and suggest a
    first batch — say five — you choose, I import. More is one ask away."
  - *I'll pick* — they name pages or a topic; curated mode on their picks.
  - *Import everything shared* — bulk mode; the full bootstrap.
  The recommendation is an offer, never a limit. Do not open with a
  pre-scoped "here are your top 5" — invite first.

## Curated mode — recommend, select, promote

Shortlist signals are recency + hierarchy position + title relevance — the
API exposes no favorites/popular signal.

1. **Gather candidates:**
   ```bash
   bash bin/connector-notion.sh list --max 30
   bash bin/connector-notion.sh search "<user's topic, if any>" --max 15
   ```
2. **Suggest a starting set** (about five when recommending). Prefer recently
   edited, top-level (parent_type `workspace`), and titles matching org
   concerns (strategy, handbook, decisions, roadmap, pricing). Present via
   AskUserQuestion (multiSelect: true) with title + last-edited date per
   option, and say plainly that they can add anything not listed or ask for
   more rounds.
3. **Fetch each selected page:**
   ```bash
   bash bin/connector-notion.sh get <page-id>
   ```
   Clean markdown with YAML frontmatter (title, notion_id, notion_url, dates,
   properties). The fetch is also cached under `~/.egregore/context/notion/`.
4. **Analyze** (agent judgment, per page): 2–3 sentence summary, 3–5 topics,
   mentions matched against known org people, related quests.
5. **PII flag:** scan for external-domain emails, phone numbers, personal
   addresses. Flag findings to the user before promotion; let them exclude.
6. **Review:** AskUserQuestion per page — Confirm / Edit metadata / Skip
   (`--auto` skips this and step 5's pause, still logging flags).
7. **Write the promoted file** to
   `memory/knowledge/sources/notion/YYYY-MM-DD-<slug>.md`:
   ```markdown
   ---
   title: <title>
   type: source
   origin: notion
   notion_id: <id>
   notion_url: <url>
   author: <promoting user>
   date: <today>
   summary: <summary>
   topics: [<topics>]
   mentions: [<people>]
   quests: [<quests>]
   ---

   <cleaned markdown body>
   ```
8. **Knowledge manifest** (the only sanctioned graph write — never raw
   Cypher) at `memory/ingest/knowledge/notion/notion-<page-id>.json`:
   ```json
   {
     "schema": "egregore-knowledge-projection/v1",
     "manifest_id": "notion:<page-id>",
     "producer_session": "<session-id>",
     "pipeline": { "name": "egregore-ingest-notion", "version": 1 },
     "source": {
       "kind": "notion",
       "id": "notion:<page-id>",
       "title": "<title>",
       "file_path": "knowledge/sources/notion/<file>.md",
       "external_ref": "<notion_url>",
       "people": [{ "ref": "<promoting-user>", "kind": "member" }]
     },
     "artifacts": [],
     "relations": []
   }
   ```
   Add `artifacts` entries only for durable knowledge you extracted into
   `memory/knowledge/{decisions,findings,patterns}/` files.
9. **Project:**
   ```bash
   bash bin/ingest-graph.sh validate memory/ingest/knowledge/notion/<manifest>.json
   bash bin/ingest-graph.sh apply memory/ingest/knowledge/notion/<manifest>.json
   ```
   If the projection reports `unavailable-in-local-mode`, the instance's
   mode config is inconsistent with the tier gate — stop and have them re-run
   `egregore connect` instead of declaring success.

## Bulk mode — export tree into corpus intake

The corpus pipeline handles identity, chunking, retrieval, and graph
provenance; the connector only produces the markdown tree.

1. **Export:**
   ```bash
   bash bin/connector-notion.sh export <root-page-id|--all> \
     --out .egregore/notion-export/<source-id> --source <source-id>
   ```
   Source id convention: `notion-<workspace-or-scope>` (stable across reruns).
   Report page/asset counts and any errors from the export result.
2. **Intake:**
   ```bash
   bash bin/ingest.sh add .egregore/notion-export/<source-id> \
     --source <source-id> --name "<human name>" --kind notion-export \
     --boundary <key=value> --prune
   ```
   `--prune` is correct here because each export is an authoritative full
   snapshot of the shared scope; drop it for partial/subtree re-exports.
   Boundaries per the source contract (e.g. `customer=`, `project=`).

   **Refresh later** (edits, new shares, deletions in Notion):
   ```bash
   bash bin/connector-notion.sh sync .egregore/notion-export/<source-id>
   bash bin/ingest.sh add .egregore/notion-export/<source-id> \
     --source <source-id> --name "<human name>" --kind notion-export \
     --boundary <key=value> --prune
   ```
   **Repeat the exact `--boundary` flags from the original intake** — intake
   overwrites stored boundaries with whatever the command supplies, so
   omitting them silently strips the source's fail-closed retrieval
   boundaries. Only changed pages move; unchanged documents are hash-skipped.
3. **Verify retrieval** (the ingestion is not done until this passes):
   ```bash
   bash bin/ingest.sh status
   bash bin/ingest.sh search "<a phrase you saw in the export>" --source <source-id> -n 5
   ```
4. Promotion of individual documents follows the corpus rules in
   `.claude/skills/ingest/SKILL.md` §4 (source chunks required).

## Completion report

State: mode, pages fetched/exported, assets, extraction or export errors,
where files landed, graph result (`synced`; an `unavailable-in-local-mode`
result means inconsistent mode config — surface it, never call it success),
and the next
step (curated: nothing pending; bulk: promotion candidates). When only a few
pages were imported, close with the standing offer: the rest of their shared
Notion can join Egregore memory any time — one sentence, not a pitch.

Telemetry (fire-and-forget, no content):
```bash
bash bin/telemetry.sh emit "command" '{"command":"ingest","kind":"notion"}' 2>/dev/null &
```
