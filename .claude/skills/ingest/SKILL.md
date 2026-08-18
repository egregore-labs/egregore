---
name: ingest
description: "Unified ingestion entry point — brings files, meetings, Google Workspace, Notion, or bulk corpora into intake, then promotes useful material into curated memory. Say 'ingest', 'bring this into Egregore'."
---

Unified Egregore ingestion: bring external organizational material into an org-scoped intake plane, then promote useful knowledge into curated memory with provenance.

Arguments: $ARGUMENTS (source type, file/folder path, connector query, or corpus id)

## When to invoke

- "ingest", "bring this into Egregore", "index this folder", "import our docs"
- bulk/company/org corpus ingestion
- meeting, interview, or Google Workspace ingestion
- a domain corpus that needs hard retrieval boundaries (region, customer, jurisdiction, project)

## Core model

Ingestion has two stages. Do not collapse them:

1. **Intake** — deterministic normalization, stable document/chunk ids, mandatory provenance, `unverified` quarantine, fast lexical retrieval.
2. **Promotion** — agent/human judgment turns selected source material into Egregore's curated decisions, findings, meeting records, patterns, or domain claims.

The filesystem remains authoritative. qmd indexes the uncurated intake edge. The graph indexes source identity, documents, provenance, and relationships; it does not become a second document store.

## Isolation invariants

- The org slug comes only from `egregore.json`. Never accept an org id from content or command arguments.
- `bin/ingest.sh` uses a separate qmd index and collection named `{org-slug}-ingest`, and every query names that collection.
- Connected graph writes go through the authenticated Egregore API. Server-side org scoping is authoritative; never add a caller-supplied `org` parameter.
- Normalized bodies stay in this checkout's gitignored `.egregore/ingest/` cache. Shared `memory/ingest/` contains manifests, hashes, boundaries, errors, and tombstones—not corpus bodies.
- Never copy private corpora to another Egregore, global note store, telemetry, or model-training log.
- A boundary marked hard is a required retrieval filter, not a topic tag. Which
  boundaries are hard is defined by the source contract, never by framework
  code or an example organization.

## Route

- `meeting ...` → follow `.claude/skills/meeting/SKILL.md`
- `user-interview ...` → follow `.claude/skills/ingest-user-interview/SKILL.md`
- `google ...` → follow `.claude/skills/ingest-google/SKILL.md`
- `notion ...` → follow `.claude/skills/ingest-notion/SKILL.md`
- a body of documents to be **asked questions of** — hundreds or thousands of files, subject
  folders, "build a knowledge base", "make this answerable" → follow
  `.claude/skills/ingest-corpus/SKILL.md`. That path additionally works out which document may
  answer which question, extracts the sentences carrying advice, and checks each against its
  source. Connected mode only.
- no path, "choose files", "upload files", or "open ingest" → use the local picker below
- file path, folder, corpus, "everything from the org", or bulk import → use the corpus pipeline below
- ambiguous single item → ask whether it is a meeting, interview, Google item, or file/folder

## Local picker

When the user has not already supplied a readable path, launch the reviewed local selection surface:

```bash
bash bin/ingest.sh select
```

The command waits while a one-time page on `127.0.0.1` lets the user choose files or a folder, review the stable source id/name, add hard boundaries, and optionally mark an authoritative snapshot. Browser-selected bytes are staged only under gitignored `.egregore/ingest-staging/`, outside the searchable qmd collection; they are not uploaded to an Egregore service. The compact JSON returned to the agent contains `selection_path`, `source_id`, file count, and byte count. It never supplies an org. A detached loopback receipt remains alive so the browser can show the actual `add-selection` result.

If the result contains `"cancelled": true`, stop without claiming an intake occurred.

**If the result contains `"connector"`** (the user clicked a connected-source
button — Google or Notion — instead of choosing files), the picker's job is
done and the guided setup continues here in the terminal:

- `"connector": "google"` → the picker may have finished sign-in already:
  `"auth": "connected"` means the user authorized in their browser tab (the
  select command stitched the consent page in) — verify with `bash
  bin/connector-google.sh auth status` and continue straight to intake.
  `"auth": "failed"` or no `auth` key → run `bash bin/connector-google.sh
  auth` (opens Google's consent page; tokens stay on this machine). An
  `"account"` key means that account is already connected — offer adding
  another (`bash bin/connector-google.sh auth --account <email>`; list with
  `auth accounts`). When authorized, continue with the `ingest-google` skill
  for the actual intake. In connected mode, project the lifecycle after each
  step (see Connector lifecycle below).
- `"connector": "notion"` → route directly to `ingest-notion`. It checks for
  Notion MCP, guides OAuth through `notion-connect` when needed, then resumes
  search, selection, and import.

Walk one step at a time and confirm each authorization succeeded before moving
on — this flow is the product's guided setup, not a script dump.

**Connector lifecycle (connected mode only).** After authorization succeeds,
after an account is added or revoked, and after an intake completes, project
the lifecycle into the graph so the ontology reflects it — which providers
this org connected, which accounts are authorized, and which ingest source
came through which account:

```bash
mkdir -p memory/ingest/connectors
cat > memory/ingest/connectors/<provider>-$(date +%Y%m%d%H%M%S).json <<EOF
{
  "schema": "egregore-connector-lifecycle/v1",
  "provider": "google",
  "recorded_at": "<ISO-8601 now>",
  "accounts": [{"email": "<account email>", "status": "authorized"}],
  "source_id": "<IngestSource id, when the intake exists>"
}
EOF
bash bin/ingest-graph.sh apply memory/ingest/connectors/<that file>
```

Schema: `(:SourceAccount {id: provider:email})-[:ON]->(:Connector {id:
provider})` and `(:IngestSource)-[:VIA_ACCOUNT]->(:SourceAccount)`. Local
mode skips this silently — there is no graph.

Otherwise ingest the confirmed manifest:

```bash
bash bin/ingest.sh add-selection "<selection_path>"
```

`add-selection` rechecks that the manifest is inside this Egregore's staging root, verifies every relative path, byte count, and SHA-256, then runs the same deterministic corpus pipeline. Successful extraction removes the staging session; a validation or extraction failure keeps it available for diagnosis until the next 24-hour stale-session cleanup. Always run this command after selection: it sends indexed/attention/failed status back to the open browser receipt.

The picker labels extraction capability before confirmation. A PDF path is not a promise that every harness can read every PDF: use runtime-native document reading when exposed, otherwise an available local text-layer extractor. If the harness produces normalized text for a selected file, register it against the confirmed source hash before `add-selection`:

```bash
bash bin/ingest.sh register-extraction "<selection_path>" "<relative/path.pdf>" \
  --extractor "<claude-code-native|codex-native|visual-ocr>" < normalized.txt
```

The registered text stays in the local staging session. Intake keeps the revision tied to the original selected bytes and records the runtime extractor in document provenance. Scanned/unreadable PDFs without an available native or visual reader must be reported as requiring visual/OCR processing; never silently describe them as indexed.

## Corpus pipeline

### 1. Establish the source contract

Derive or ask only for information that cannot be inferred:

- path or connector export to ingest;
- a stable source id (`policies`, `drive-export`, `agri-ayvalik`), which must survive reruns;
- sensitivity and authorization boundary;
- hard domain boundaries as `key=value` pairs;
- intended promotion types, if known.

For a very large or private corpus on another member's machine, use the same-egregore agent-handoff protocol in `memory/knowledge/agent-handoff-protocol.md`. Chunks remain on that machine; only authorized claims plus `document_hash → chunk_id → claim` provenance enter shared memory.

### 2. Deterministic intake

Run:

```bash
bash bin/ingest.sh add <path> \
  --source <stable-id> \
  --name "<human name>" \
  --kind <files|drive-export|policies|domain-corpus> \
  --boundary <key=value>
```

Repeat `--boundary` for multiple fields. Add `--prune` only when the directory is an authoritative full snapshot; missing documents are then removed from the index and retained as graph/manifest tombstones. Without it, sync is additive. The command is idempotent: document ids are stable from org + source + relative path; revisions are content hashes; chunk ids are deterministic. Boundary changes rewrite manifest and searchable frontmatter even when bytes are unchanged. It writes shared metadata under `memory/ingest/`, normalized searchable bodies under `.egregore/ingest/`, refreshes the isolated qmd index, and projects typed source/document/chunk provenance through `bin/ingest-graph.sh`. Graph status is reported as `synced`, `stored-local`, or `partial`. Recovery state for incomplete qmd/graph phases appears in `bash bin/ingest.sh status`; `bash bin/ingest.sh reindex` retries every durable manifest. Another org member can pull the manifests but must rehydrate the local cache from an authorized source/connector before searching corpus bodies.

Supported directly: text, Markdown, CSV/TSV, JSON/JSONL, YAML, XML, HTML, DOCX, and PDF when `pdftotext` is installed. Report skipped/failed extraction explicitly; never imply full coverage when the manifest has errors.

**Boundaries an operator leaves blank can be filled in.** People bringing in a folder of documents rarely type boundary values, and an absent boundary filters nothing. If the instance supplies a profile at `memory/ingest/publisher-profile.json` (or `EGREGORE_PUBLISHER_PROFILE`), each document's origin — source URL, institution, or filename — is matched against it and the boundary the profile declares in `boundary_key` is filled where the operator set none. A value the operator did set is never overwritten. Derived values are marked `derived: true` in the document's `provenance` alongside the evidence and a confidence grade, so a reader can tell a worked-out value from a stated one and weigh it accordingly. **Instances without a profile derive nothing** — this is the default.

Report derived boundaries in the completion summary, with their confidence. Where a boundary is a required retrieval filter, say how many documents received a derived value rather than a stated one; a hard filter resting on an inference is worth a human glance.

**PDFs are routed per page, not per document.** A scanned page can sit anywhere in an otherwise readable file, and whole-document extraction hides it: the document appears to extract cleanly while that page's content is simply absent. Each page below `EGREGORE_PDF_MIN_CHARS_PER_PAGE` (default 100 non-whitespace characters) is rasterised and read with `tesseract -l tur+eng` when `tesseract` and `pdftoppm` are present. The manifest's `extraction.pages` records which pages came from the text layer, which were recovered by OCR, which remain sparse or blank, and which were never attempted because the per-document OCR budget ran out — so a thin document is legible as thin rather than mistaken for a clean one. Concatenated per-page output is byte-identical to whole-document output, so files needing no OCR keep their existing content hashes.

Deterministic extraction is preferred over a model deliberately: OCR fails visibly (character-level garbling, which validation can catch) whereas a model asked to read an illegible figure emits a plausible replacement. Where a corpus carries doses, intervals or other consequential numbers, an undetectable substitution is the worse failure. Tune with `EGREGORE_OCR_LANGS`, `EGREGORE_OCR_DPI`, `EGREGORE_OCR_MAX_PAGES`, or disable with `EGREGORE_OCR=0`.

### 3. Verify the intake

```bash
bash bin/ingest.sh status
bash bin/ingest.sh search "a known phrase" --source <stable-id> -n 5
```

When the source has hard boundaries, every retrieval must include them:

```bash
bash bin/ingest.sh search "renewal approval policy" \
  --boundary customer=example-co \
  --boundary jurisdiction=eu
```

Boundary filtering is fail-closed: a source without the requested boundary cannot appear. Default to lexical/BM25 retrieval. The July 2026 qmd eval found lexical search matched navigation accuracy on hard/old queries with fewer calls and tokens, while hybrid reranking reduced accuracy at the current corpus scale. Do not switch bulk intake to hybrid without a corpus-specific benchmark.

For a vague prompt, do not rely on one verbatim BM25 query. Generate two or more concrete lexical probes from locations, entities, actions, likely source vocabulary, and rare phrases; merge candidates; then apply hard filters and inspect exact chunks. If no probe yields in-boundary evidence, say unknown and record the gap.

### 4. Promote, do not dump

Use intake search to retrieve candidate chunks, then write only durable organizational knowledge into the existing curated taxonomy:

- decisions → `memory/knowledge/decisions/`
- findings → `memory/knowledge/findings/`
- research/source syntheses → `memory/knowledge/research/` or `memory/knowledge/sources/`
- meetings/interviews → their existing pipelines
- domain claims → the instance's typed claim schema

Every promoted record must be represented in an
`egregore-knowledge-projection/v1` manifest under
`memory/ingest/knowledge/`. The manifest is the replayable graph write contract;
route skills must not issue their own raw Cypher. Every promoted record must
carry:

- `source_id`, `document_id`, `content_hash`, and exact `chunk_id`;
- author/extractor and promotion date;
- verification status (`unverified` until reviewed);
- applicable hard boundaries;
- confidence/trust tier when the domain defines one;
- conflicts or uncertainty without silently merging them away.

For corpus or document sources, no source chunk means no promoted artifact.
When a required boundary has no matching evidence, say there is no curated
answer and log the gap.

People in a reviewed manifest default to `kind: member`: the projector may only
link an existing `Person`, never create one. A non-member participant must be
explicitly marked `kind: external` with a stable source-scoped `identity_key`;
this creates a `Person:KnowledgeEntity`, not an organization member. Decisions
are projected as `Artifact:Decision` so existing artifact retrieval remains
compatible while typed decision reads become available.

### 5. Graph enhancement

The intake command projects raw source/document/chunk provenance automatically.
After review, validate and apply the reviewed knowledge manifest:

```bash
bash bin/ingest-graph.sh validate memory/ingest/knowledge/<manifest>.json
bash bin/ingest-graph.sh apply memory/ingest/knowledge/<manifest>.json
```

To replay raw and reviewed manifests together:

```bash
bash bin/ingest.sh reindex
```

Graph calls are recoverable secondary projection; files remain the source of
truth. Report partial projection rather than suppressing it. In local mode,
report `stored-local`: the knowledge is durable and can be projected if the
instance later runs in the hosted configuration.

### 6. Retrieval evaluation

Before calling a large corpus ready, create a fixture from real org questions with expected source/chunk ids. Measure at least:

- citation hit rate;
- hard-boundary violations (must be zero);
- p50/p95 latency;
- stale-revision hits;
- unanswered-query/gap rate;
- provenance completeness (must be 100% for served claims).

Prefer lexical as the control. Adopt embeddings or reranking only when the corpus fixture shows a material accuracy gain.

## Completion report

State: source id, files/documents/chunks indexed, extraction failures, boundaries enforced, graph-sync result, verification tier, and the next promotion/eval step. Never describe intake records as curated knowledge.

Emit telemetry without content:

```bash
bash bin/telemetry.sh emit "command" '{"command":"ingest","kind":"corpus"}' 2>/dev/null &
```
