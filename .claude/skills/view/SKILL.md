Generate a branded HTML artifact from Egregore data and open it in the browser.

Works in both connected and local mode — resolves data from memory files, not the graph.

## When to invoke

User says: "show me visually", "render this", "view as artifact", "open in browser",
"make this readable", "generate artifact", "show me [quest/handoff/plan]", "/view"

Not this: terminal formatting → just format in markdown · dashboard → `/dashboard`

Arguments: $ARGUMENTS (Optional: artifact type and/or name, or a file path)

## Supported artifact types

- `quest` — renders quest markdown from `memory/quests/`
- `handoff` — renders handoff markdown from `memory/handoffs/`
- `activity` — renders live team activity dashboard (no file needed)
- `board` — renders project board from `memory/board/board.json` (no file needed; interactive editor with paste-back loop, 5 tabs: Activity / Priority / Person / Timeline / Done). In connected mode, also publishes to a stable URL at `egregore.xyz/view/{org}/board` on every invocation — bookmark it and refresh to see the latest.
- `network` — renders people/relationship network (no file needed)
- `document` — renders any markdown file with branded styling (auto-detected fallback)

## Resolution logic

The key job of `/view` is resolving what the user wants to see into a file path. This must work without a graph.

### 1. Parse the arguments

- `/view quest artifact-generation` → type=quest, name=artifact-generation
- `/view handoff oss-security-audit` → type=handoff, name=oss-security-audit
- `/view activity` → type=activity, no file needed
- `/view board` → type=board, reads `memory/board/board.json`, no file argument needed
- `/view network` → type=network, no file needed
- `/view artifact-generation` → no type specified, search all types
- `/view memory/knowledge/decisions/some-decision.md` → direct file path
- `show me the security audit visually` → extract keywords, search

### 2. Resolve the file

**Direct file path**: If the argument looks like a file path (contains `/` or ends in `.md`), resolve it directly. If it exists, use it — type is auto-detected from location or falls back to `document`.

**Quest**: Search `memory/quests/` for `{name}.md` or partial match:
```bash
# Exact match
FILE="memory/quests/${name}.md"
# Partial match — find files containing the name
ls memory/quests/*.md | grep -i "$name" | head -1
```

**Handoff**: Search `memory/handoffs/` recursively (files are in date subdirectories):
```bash
# Search all subdirectories
find memory/handoffs/ -name "*.md" -not -name "index*" | grep -i "$name" | head -1
# If multiple matches, prefer most recent (sorted by path which includes date)
find memory/handoffs/ -name "*.md" -not -name "index*" | grep -i "$name" | sort -r | head -1
```

**Activity**: No file resolution needed — runs `bin/activity-data.sh` live.

**Board / Network**: No file resolution needed. `board` reads `memory/board/board.json` automatically (via git root). `network` is generated from people data.

**Auto-detect type** (no type specified):
1. Search `memory/quests/` first
2. Then `memory/handoffs/` recursively
3. Then `memory/knowledge/` recursively
4. If found, infer type from location (`quest` or `handoff`) — everything else is `document`

### 3. Generate and open

For typed artifacts with a file:
```bash
npx egregore-artifacts <type> <resolved-file-path>
```

For auto-detected (just a file path):
```bash
npx egregore-artifacts <resolved-file-path>
```

For activity (no file):
```bash
npx egregore-artifacts activity
```

**For board (connected mode only — publish to stable URL):**

After opening locally, fire-and-forget a publish with a stable `--id` so the URL `egregore.xyz/view/{org}/board` always shows the latest board:

```bash
_API_URL=$(jq -r '.api_url // empty' egregore.json 2>/dev/null)
_MODE=$(jq -r '.mode // empty' egregore.json 2>/dev/null)
if [ -n "$_API_URL" ] && [ "$_MODE" != "local" ]; then
  ORG_NAME=$(jq -r '.org_name // .slug' egregore.json)
  bash bin/publish-artifact.sh board memory/board/board.json \
    --id board \
    --title "Project Board — $ORG_NAME" \
    --author "$ORG_NAME" \
    --description "Latest board for $ORG_NAME" 2>/dev/null &
fi
```

The publish script exits silently on failure, so the local open always succeeds regardless of API state. OSS/local mode skips this step entirely — the board stays local unless the user publishes explicitly.

### 4. Report

```
✓ Artifact opened in browser
  File: /tmp/egregore-artifacts/{type}-{name}-{ts}.html
```

For `/view board` in connected mode, append:
```
◆ https://egregore.xyz/view/{org_slug}/board   (stable — refresh for latest)
```
Read `org_slug` from `egregore.json`.

## Fallback

If `npx egregore-artifacts` fails (not installed), install it first:
```bash
npm install -g egregore-artifacts
```

## Ambiguity handling

If the name matches multiple files, use AskUserQuestion:
```
Found multiple matches for "security":
1. handoffs/2026-03/31-cem-oss-security-audit.md
2. quests/oss-security-review.md
Which one?
```

If no matches found, **fall through to synthesis mode** (see below).

## Synthesis mode

When the input is a prompt or topic rather than a file name — or when file resolution finds nothing — synthesize an artifact from multiple sources.

1. **Read relevant files** — search memory/, codebase, and conversation context for material matching the prompt. Read as many files as needed.
2. **Write a temporary markdown file** — synthesize the findings into a well-structured document at `/tmp/egregore-artifacts/synthesized-{slug}.md`. Use headings, lists, code blocks — the renderer handles all standard markdown.
3. **Render it** — `npx egregore-artifacts document /tmp/egregore-artifacts/synthesized-{slug}.md`
4. **Report** — same as normal: `✓ Artifact opened in browser`

This is the default fallback — don't ask the user if they want synthesis. If `/view auth architecture` doesn't match a file, just do the research and render it.

**When to synthesize vs. when to say "not found":**
- Prompt is a topic/question ("auth architecture", "how does onboarding work") → synthesize
- Prompt looks like a filename that should exist but doesn't ("my-missing-doc") → say not found
- Use judgment — if the user clearly expects a specific file, don't synthesize a guess

## Examples

```
> /view quest artifact-generation

✓ Artifact opened in browser
  File: /tmp/egregore-artifacts/quest-artifact-generation.html
```

```
> show me the security audit visually

Resolving "security audit"...
  Found: memory/handoffs/2026-03/31-cem-oss-security-audit.md

✓ Artifact opened in browser
  File: /tmp/egregore-artifacts/handoff-31-cem-oss-security-audit.html
```

```
> /view memory/knowledge/decisions/auth-redirect.md

✓ Artifact opened in browser
  File: /tmp/egregore-artifacts/document-auth-redirect.html
```

```
> /view activity

✓ Artifact opened in browser
  File: /tmp/egregore-artifacts/activity-2026-04-06.html
```

```
> /view auth architecture

No file match — synthesizing from codebase...
  Reading: api/main.py, api/auth.py, api/services/supabase.py, ...

✓ Artifact opened in browser
  File: /tmp/egregore-artifacts/document-auth-architecture.html
```
