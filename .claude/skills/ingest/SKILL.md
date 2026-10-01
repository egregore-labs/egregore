---
name: ingest
description: "Route and run organizational ingestion through Egregore Runtime for files, folders, meetings, Google Workspace, Notion, interviews, or bulk corpora. Use for 'ingest', 'bring this into Egregore', 'index this folder', or 'import our docs'."
---

# Ingest

Route external material into an authorized intake plane, then promote selected
evidence into curated organizational memory. Do not collapse intake and
promotion.

## When to invoke

Route and run organizational ingestion through Egregore Runtime for files, folders, meetings, Google Workspace, Notion, interviews, or bulk corpora. Use for 'ingest', 'bring this into Egregore', 'index this folder', or 'import our docs'.

## Route

- One URL/document/reference → use the `add` skill and `bin/ingest-item.sh`.
- `meeting ...` → use the meeting skill.
- `user-interview ...` → use the ingest-user-interview skill.
- `google ...` → use the ingest-google skill.
- `notion ...` → use the ingest-notion skill.
- A large question-answering corpus or “build a knowledge base” → use the
  ingest-corpus skill and keep its Connected capability gate.
- No readable path → `bash bin/ingest.sh select`.
- File/folder/export/bulk path → use the corpus pipeline below.
- Ambiguous → ask which source class applies; do not guess a connector.

Preserve connector authorization/revocation in connector-specific Runtime
adapters. This skill must not write connector lifecycle files or project state.

## Invariants

- Resolve organization only from the active Egregore instance, never content or
  arguments.
- Keep selected/unverified bytes in gitignored local staging/quarantine.
- Canonical shared state contains admitted Markdown or reference manifests with
  stable ids, revisions, provenance, boundaries, errors, and tombstones.
- Register canonical state successfully before any derived retrieval refresh.
- Hard boundaries are authorization filters, never descriptive tags. Missing
  required boundary evidence fails closed.
- Graph projection is optional and cannot complete, block, or override intake.
- Telemetry contains structured counts/status only, never source content.

## Local selection

When no path was provided:

```bash
bash bin/ingest.sh select
```

If cancelled, stop. If it returns a Google or Notion connector, continue in
that connector skill. Otherwise always submit the reviewed selection, using
`{selection-path}` for the selection path printed by the select command:

```bash
bash bin/ingest.sh add-selection '{selection-path}'
```

The selection adapter verifies staging containment, relative paths, byte
counts, and hashes before extraction. Register harness-native extraction for a
selected PDF only when the reader actually produced normalized text; `{selection-path}`
is the select command's returned path, `{relative-pdf-path}` is the selected PDF's path
relative to the selection root, `{extractor}` identifies the reader that produced the
text, and `{normalized-file}` is the normalized text file written under `tmp/`:

```bash
bash bin/ingest.sh register-extraction '{selection-path}' \
  '{relative-pdf-path}' --extractor '{extractor}' < '{normalized-file}'
```

Report unreadable/scanned pages; never imply complete extraction.

## Corpus intake

Infer only safe metadata. Ask for a stable source id, sensitivity/visibility,
hard boundaries, and whether the directory is an authoritative snapshot.

Use `{source-path}` for the user-selected file or folder, `{source-id}` for the user's
stable source id, `{name}` and `{kind}` for the reviewed source name and content kind,
and `{boundary}` for a user-confirmed `key=value` boundary:

```bash
bash bin/ingest.sh add '{source-path}' \
  --source '{source-id}' \
  --name '{name}' \
  --kind '{kind}' \
  --boundary '{boundary}'
```

Repeat boundaries. Use `--prune` only for an explicitly authoritative full
snapshot. The adapter owns deterministic extraction, stable document/chunk
identity, local quarantine, canonical manifest registration, retrieval refresh,
and background embedding. Skills do not invoke those mechanics separately.

## Verify

```bash
bash bin/ingest.sh status
```

Use `{known-phrase}` for a phrase observed in the admitted source and `{source-id}` for
the stable source id supplied during intake:

```bash
bash bin/ingest.sh search '{known-phrase}' --source '{source-id}' -n 5
```

Include every required hard boundary in verification searches. Open exact
evidence before making consequential claims. Report indexed/skipped/failed
counts and gaps honestly.

## Promote

Intake is not curated knowledge. Retrieve candidate evidence, open its exact
source, then use the appropriate Runtime ritual for a decision, finding,
research synthesis, meeting, or domain claim. Preserve source id, document id,
revision/content hash, exact chunk ids, boundaries, reviewer, confidence, and
conflicts. No evidence chunk means no promoted claim.

## Completion

Report source id, documents/chunks admitted, extraction failures, boundaries,
canonical manifest/writeback status, semantic-build state, and next review or
promotion step. Do not run a second save, index, telemetry, or projection step.
