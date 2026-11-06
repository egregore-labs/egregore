---
name: dark-mode
description: "Use when authoring or modifying browser-rendered visual output: HTML, CSS, React SSR, artifact templates, markdown renderers, design tokens, themes, or composed pages. Do not invoke for an ordinary /view render—the checked-in renderer already owns its theme contract. The load-bearing rule is that theme-sensitive colors must be emitted as `var(--token)`, never resolved inline hex; the colors themselves come from the design system registry."
---

# Dark Mode

## Voice Complex

This skill governs browser visual rendering: theme tokens and theme behavior. It carries no palette; every color comes from the design system.
Shared aesthetic: voice-bedrock (`.claude/rules/voice-bedrock.md`).
For pair routing, component profiles, or adding a pair: `packages/design-system/skill/SKILL.md`.
For terminal rendering: `tui-design` skill.
For product copy in rendered pages: `product-voice` skill.
For prose content in rendered pages: `egregore-voice` skill.

## When to invoke

User says: "dark mode", "theme toggle", "color system", "card surface", "make this work in dark mode", or any request to generate or modify browser-rendered visual output (HTML, CSS, React SSR, Egregore artifacts, design tokens).

Not this:

- An ordinary deterministic `/view` render; the checked-in renderer already
  owns and tests its theme contract
- TUI terminal output; use `tui-design`
- Plain markdown files that do not render styled HTML
- Backend or CLI code with no visual surface

## The rule

If a renderer emits `style="color:#15212e"`, theming loses: CSS can re-theme a value only when the rendered value is itself a variable reference. Every theme-sensitive color, in a stylesheet or an inline `style` prop, is `var(--token)` at the render site.

## Where colors come from

- **Registry**: `packages/design-system/themes/registry.json` holds every palette pair and its theme tokens. The default pair is `registry.routing.defaultPair`, currently `sovereign` (`ledger` light, `bedrock` dark: cool stone with verdigris and steel accents). Use another registered pair only when the content matches that pair's `semantics.useWhen` and you can state the reason.
- **CSS**: inline the committed, generated `packages/design-system/dist/egregore-design.css`. It defines each theme as a `[data-theme="<theme id>"]` block plus legacy aliases (`--bg`, `--text`, `--accent` and the rest). Never copy its values into a page and never edit it by hand; `npm run build` in `packages/design-system` regenerates it from the registry.
- **Without the design package**: public and downstream instances do not carry `packages/design-system`. The same files ship vendored in `egregore-artifacts`, both in a checked-out `packages/egregore-artifacts` and in the installed package: `lib/vendor/design-system/themes/registry.json` and `lib/vendor/design-system/dist/egregore-design.css`.
- **Tokens**: use the role tokens from `contract.roleTokens`: `--paper --paper-2 --card`, `--ink --ink-soft --ink-faint`, `--line --line-soft`, `--t1 --t2 --t3` with their `-bg` washes, the tone tokens `--ok --note --warn --critical --neutral` with their `-bg` washes, `--series-1` to `--series-5` with `--chart-grid --chart-axis` for charts, and `--grain --shadow`.
- **Status colour**: read meaning from the tone tokens, never from `--t1`..`--t3` positions. The meaning is the same in every pair: `--ok` decided or done, `--note` aside or context, `--warn` owed or gated, `--critical` blocked or at risk, `--neutral` background or later.
- **No local palette**: a page or a skill never defines its own theme colors. If the role tokens do not cover a color you need, that is a registry change; see the design system skill.

## Highlights

No side stripes: a coloured bar down one side of a box is retired in every render. Mark reading emphasis with a marker under the words (`.eg-mark`), a label in the margin (`.eg-margin` holding an `.eg-label`) or a quote with a hanging opening mark (`.eg-quote`). Mark status with a quiet panel (`.eg-panel`) whose `.eg-label` carries the tone's shape (● ok, ◆ note, ▲ warn, ■ critical, ○ neutral), so the state reads without colour and in both themes. A selected item gets weight plus a filled shape, never a stripe. The classes are `RECIPE_CSS` in `packages/egregore-artifacts/lib/recipe.js`, which the kit's shell injects into every render; the design system skill has the full rule.

## The theme contract

The kit's renderers set three attributes on `<html>`:

| Attribute | Value | Role |
|---|---|---|
| `data-theme` | resolved theme id, e.g. `ledger` or `bedrock` | the only CSS selector |
| `data-theme-pair` | pair id, e.g. `sovereign` | names the family; never a CSS selector |
| `data-theme-mode` | `auto`, `light` or `dark` | the reader's choice |

- Persist only the mode. Resolve it through the pair: `auto` follows `prefers-color-scheme`, with the local clock as the fallback, and the result writes the pair's light or dark member into `data-theme`.
- Resolve before paint, in a blocking `<head>` script.
- Storage can throw in sandboxed and private pages: wrap every read and write in try/catch and keep the mode in memory.
- Reference implementation: the theme script in `packages/egregore-artifacts/lib/shell.js` (a three-state toggle, `light → auto → dark`). Reuse its structure; do not write a second engine.

## Anti-Patterns

| Pattern | Why It Breaks | Instead |
|---|---|---|
| `style={{ color: palette.ink }}` with a JS constant | SSR resolves the constant to a fixed hex, so the theme cannot override it | `style={{ color: 'var(--ink)' }}` or a class |
| `background: white` on cards | The card stays white in a dark theme | `background: var(--card)` |
| `border: 1px solid rgba(0, 0, 0, 0.08)` | A light-only value inside a themeable component | `var(--line)` or `var(--line-soft)` |
| `[data-theme="dark"]` overrides or `.dark-*` classes | Theme ids are names like `bedrock`, and role tokens already flip per resolved theme | Style with role tokens; add no per-mode overrides |
| Selecting on `data-theme-pair` | The pair names the family; it is not a selector | Use role tokens, or `[data-theme="<theme id>"]` when one theme needs its own rule |
| `opacity: 0.5` on colored text | Contrast changes unpredictably between themes | `var(--ink-soft)` or `var(--ink-faint)` |
| `@media (prefers-color-scheme: dark)` as the only mechanism | No manual override and no persistence | The three-state mode above |
| Theme state on `body` or a wrapper div | Portals, overlays and shells fall out of sync | The three attributes on `<html>` |
| Restoring the saved mode after the page renders | A flash of the wrong theme | A blocking `<head>` script |

## Context Modes

- **Egregore artifacts** (`packages/egregore-artifacts`): the shell inlines the design CSS, bridges legacy chrome names onto role tokens, and runs the theme script. Component code uses role tokens only.
- **Python pages** (`api/`): `api/design_system.py` (`design_head`, `html_attrs`, `bridge_css`) reads the same dist CSS and registry as static files.
- **Standalone HTML**: inline the dist CSS, set the three attributes on `<html>`, and add the `<head>` theme script.
- **Tailwind**: map utilities to role-token variables (for example `ink: 'var(--ink)'`); do not use the `dark:` variant for theme colors.
- **Email HTML**: the one context where `@media (prefers-color-scheme: dark)` with `!important` is correct. Build no JS toggle, and optimize for legibility over parity.

## Pre-Ship Checklist

1. No hex or resolved color constant in any render path that emits inline styles.
2. Every `var(--x)` the page uses is defined for both members of its pair (for `sovereign`: `ledger` and `bedrock`).
3. `<html>` carries all three attributes, and the mode is restored in `<head>` before paint.
4. The toggle cycles `light → auto → dark`; the choice survives a reload where storage works, and nothing throws where it does not.
5. Print and phone-width layouts still work.
