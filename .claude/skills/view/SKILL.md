Generate a branded HTML artifact from Egregore data and open it in the browser.

Works in both connected and local mode — resolves data from memory files, not the graph.

## When to invoke

User says: "show me visually", "render this", "view as artifact", "open in browser",
"make this readable", "generate artifact", "show me [quest/handoff/plan]", "/view"

Not this: terminal formatting → just format in markdown · dashboard → `/dashboard`

Arguments: $ARGUMENTS (Optional: artifact type and/or name)

## Supported artifact types

- `quest` — renders quest markdown from `memory/quests/`
- `handoff` — renders handoff markdown from `memory/handoffs/`
- `activity` — renders live team activity dashboard (no file needed)

## Resolution logic

The key job of `/view` is resolving what the user wants to see into a file path. This must work without a graph.

### 1. Parse the arguments

- `/view quest artifact-generation` → type=quest, name=artifact-generation
- `/view handoff oss-security-audit` → type=handoff, name=oss-security-audit
- `/view activity` → type=activity, no file needed
- `/view artifact-generation` → no type specified, search all types
- `show me the security audit` → extract keywords, search

### 2. Resolve the file

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

**Auto-detect type** (no type specified):
1. Search `memory/quests/` first
2. Then `memory/handoffs/` recursively
3. If found, infer type from location

### 3. Generate and open

```bash
node packages/egregore-artifacts/bin/cli.js <type> <resolved-file-path>
```

For activity (no file):
```bash
node packages/egregore-artifacts/bin/cli.js activity
```

### 4. Report

```
✓ Artifact opened in browser
  File: /tmp/egregore-artifacts/{type}-{name}-{ts}.html
```

## Fallback

If `packages/egregore-artifacts/node_modules` doesn't exist:
```bash
cd packages/egregore-artifacts && npm install --quiet && cd -
```

## Ambiguity handling

If the name matches multiple files, use AskUserQuestion:
```
Found multiple matches for "security":
1. handoffs/2026-03/31-cem-oss-security-audit.md
2. quests/oss-security-review.md
Which one?
```

If no matches found:
```
No artifact found matching "{name}".
Available quests: artifact-generation, egregore-reliability, ...
Try: /view quest {name} or /view handoff {name}
```

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
> /view activity

✓ Artifact opened in browser
  File: /tmp/egregore-artifacts/activity-2026-04-03.html
```
