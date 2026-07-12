---
name: view
description: 'Render Egregore data and documents as branded browser artifacts. Use when the user invokes /view or $view, asks to show something visually, open it in a browser, make a document readable or presentable, render a quest/handoff/activity/board/network, or synthesize a visual artifact from a topic.'
---

# Egregore View

Native Codex Egregore skill. Use only inside an Egregore checkout.

Resolve a file or live Egregore surface, render it with the in-repo artifact
tooling, open it, and report the concrete output path. Run the workflow inline;
do not invoke Claude Code commands or delegate through Loom.

## Structured UX parity

The visible result is the browser artifact and a compact receipt. Preserve the
typed artifact templates, designed document composition, exact file path, and
stable board URL when available. Do not replace the artifact with a prose
summary or expose raw renderer output.

## Resolve the request

1. Verify `bin/agent.sh` exists. If not, say this is not an Egregore checkout.
2. Parse an optional type followed by a name:
   - `quest` from `memory/quests/`
   - `handoff` from `memory/handoffs/` recursively
   - `activity`, `board`, or `network` with no source file
   - `document` for any markdown file
3. Treat an argument containing `/` or ending in `.md` as a direct path. Use it
   if it exists and infer the type from its directory.
4. With no explicit type, search in this order: quests, handoffs, knowledge.
   Prefer exact basename matches, then case-insensitive partial matches. For
   handoffs, prefer the newest matching dated path.
5. If several files match, use structured Codex question tooling when
   available; otherwise ask one concise plain-text question listing the paths.
6. If no file matches and the input is a topic or question, synthesize a
   temporary markdown document from relevant memory, repository files, and
   conversation context at
   `/tmp/egregore-artifacts/synthesized-<slug>.md`. If the input clearly names
   a missing file, report it as missing instead of inventing a document.

## Select the renderer

Prefer the checked-out package so local changes are exercised and no package
download is needed:

```bash
RENDER="npx egregore-artifacts@latest"
if [ -f packages/egregore-artifacts/bin/cli.js ] && \
   [ -d packages/egregore-artifacts/node_modules/react ]; then
  RENDER="node packages/egregore-artifacts/bin/cli.js"
fi
```

If the local package exists without dependencies, install its dependencies or
use the `npx` fallback. Do not block a render on optional connected services.

## Render typed artifacts

Run the matching command:

```bash
$RENDER quest <quest-file>
$RENDER handoff <handoff-file>
$RENDER activity
$RENDER board
$RENDER network
$RENDER document <markdown-file>
```

Use the renderer's reported HTML path rather than guessing it.

For documents, walk the generative-UI synthesis graph in
`packages/design-system/generative-ui/skill/SKILL.md`: select one id each for
objective, audience, register, palette, and grammar from the document's
substance, record one line of judgment for each, resolve the brief, and pass it
with `--brief`. If that layer is unavailable, render without the brief.

## Compose flagship documents

Composition is the default for a multi-section strategy, briefing, explainer,
analysis, decision document, or anything explicitly requested as composed,
presentable, client-facing, designed, or `--compose`. Use the fast renderer for
typed artifacts, short utility documents, `--fast`, or `--floor`.

For composition:

1. Read the source document in full.
2. Copy `.codex/skills/view/assets/compose-scaffold.html` to
   `/tmp/egregore-artifacts/composed-<slug>.html`.
3. Fill every placeholder and walk the generative-UI graph for the manifest's
   register, palette, grammar, and trail.
4. Transform rather than mirror the markdown:
   - write a two-tone claim-led hero and italic standfirst;
   - make section headings state findings, not repeat source headings;
   - choose components by meaning: ledger for Q/A, claims for numbers, panels
     for options, steps for sequences, feature rows for capability/status,
     threads for decisions, gap cards for negatives, and a readout for the
     honest bottom line;
   - create one anchored navigation item per composed section.
5. Keep every theme-sensitive color as `var(--token)`. Never emit inline hex
   colors in composed content. Preserve the scaffold's no-flash theme restore,
   `<html data-theme>`, and light/auto/dark behavior.
6. Verify no placeholders remain, open the HTML with the platform browser
   opener, and report `Renderer: composed (band 5, inline)`.

## Publish the stable board

After `$RENDER board`, publish best-effort only when `egregore.json` declares a
connected configuration:

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

The local artifact remains the successful result if publishing fails. In local
mode, do not call graph or notification services.

## Report

Return only the useful receipt after the browser opens:

```text
✓ Artifact opened in browser
  File: /tmp/egregore-artifacts/<rendered-file>.html
```

For a connected board, append:

```text
◆ https://egregore.xyz/view/<org-slug>/board   (stable — refresh for latest)
```

Emit telemetry best-effort after completion:

```bash
bash bin/telemetry.sh emit "command" '{"command":"view"}' 2>/dev/null &
```

## Rules

- Keep filesystem resolution sufficient in local mode; the graph is optional.
- Preserve auto-linked backtick references handled by
  `bin/publish-references.sh` when publishing markdown.
- Never install a global renderer package as the first choice.
- Never call the deprecated `egregore-handoff` CLI.
- Never claim publishing succeeded unless a URL was actually returned.
