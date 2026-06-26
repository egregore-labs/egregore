---
description: Render a real artifact through this branch's local MERIDIAN design code (not the published npm package) so the team can test the new Design Convention on the document / handoff / platform surfaces before it ships. Use for `/preview-design`, "preview the design convention", "render this with the new design", or Design Convention round-1 testing.
---

Topic: $ARGUMENTS

# Preview the Design Convention

Renders a real Egregore artifact through **this branch's** MERIDIAN render path
(`packages/egregore-artifacts` local code) — deliberately **not** `npx egregore-artifacts`,
which pulls the published npm `0.10.2` (the OLD design). This is the test vector for
Design Convention **Round 1**: testers see the new design on real output before it merges.

Full protocol: `memory/feedback/design-convention-r1/GUIDE.md`.

## When to invoke

User says: "/preview-design", "preview the design convention", "render <X> with the new
design", "let me test the new design on a document / handoff / board", or is running the
design-convention round-1 test.

## What it does

Run the bundled script — it handles dependency install and routes to the local CLI:

```bash
bash skills/preview-design/render.sh <surface> [file]
```

| Surface | Command | Input |
|---|---|---|
| `document` | `render.sh document [file.md]` | any markdown — defaults to a bundled sample |
| `handoff`  | `render.sh handoff [file.json]` | a handoff-v1 JSON — defaults to a bundled sample |
| `platform` | `render.sh platform` | reads `memory/board/board.json` (the board view) |
| `emissary` | `render.sh emissary` | **harness-only this round** — prints the harness URL and stops |

The CLI opens the rendered HTML in the browser. After looking it over, the tester runs the
Socratic feedback protocol (`"Run the Design Convention feedback protocol"`).

## Why it's built this way

- **Local, never `npx`.** It runs `node packages/egregore-artifacts/bin/cli.js`, so you
  always get THIS branch's MERIDIAN design — npm's `egregore-artifacts` is the old look.
- **Lives in top-level `skills/`, not `.claude/skills/`.** `/update` replaces
  `.claude/skills/` wholesale from upstream (`git checkout upstream -- .claude/skills/`),
  which would delete an org-local preview command. Top-level `skills/` survives.
- **Emissary is excluded on purpose.** Its renderer (`api/main.py`) is server-side and not
  yet design-system-wired — wiring it is the #1 Round-2 task. For now it's reviewed via the
  published harness.

## Lifecycle

Retire this skill once the Design Convention merges to production and a new
`egregore-artifacts` is published (at which point plain `/view` shows MERIDIAN and the
local-vs-npm distinction disappears).
