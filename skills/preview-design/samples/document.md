# The Egregore Design Convention

*A sample document — rendered through the branch's MERIDIAN code so you can judge the
document surface on realistic structure. Everything below is here to exercise the
renderer: headings, lists, a table, a code block, a blockquote, accents, and links.*

The Design Convention is **one versioned design source** — the MERIDIAN family — applied
across every primary surface. One role-token contract, three typefaces, per-surface
palette pairs. The thesis is integration: a document, a handoff, a board, and an emissary
should read as one body, not four themes wearing a shared logo.

## 01 — The type system

Three families, each with a job:

- **Fraunces** — display. Carries the editorial voice; never used for running text.
- **Hanken Grotesk** — sans. The workhorse for body and UI.
- **IBM Plex Mono** — mono. Code, metadata, and machine-facing payloads.

Hierarchy should read as *intent*, not decoration. If a heading is big, it is because it
is load-bearing — not because big looks nice.

## 02 — Palette as data

Each surface binds a **pair** (a light member and a dark member) plus one accent:

| Pair | Light | Dark | Accent |
|----------|----------|----------|--------|
| meridian | vellum | nocturne | brass |
| agronomic | loam | soil | soil |
| sovereign | ledger | bedrock | gold |

The mode (`auto` / `light` / `dark`) is the only thing persisted; the resolved theme is
derived from the pair. Flip the toggle and *everything* should move together — that is the
single most important thing to test.

## 03 — Accent discipline

> An accent earns its place by marking meaning — a decision, a contested element, a call
> to action. Used everywhere, it means nothing. The brass diamond on a divider is a
> punctuation mark, not wallpaper.

## 04 — A copyable block

Editorial surfaces often carry a machine-facing payload meant to be copied verbatim:

```
Run this Egregore: design-convention
Surface: document
Pair: meridian · Mode: auto
```

If the surface renders a copy affordance on that block, confirm it copies the exact text.

## 05 — What to judge

1. Does this read as **authoritative and editorial** — kicker, numbered sections, dotted
   dividers with the brass diamond?
2. Is the **typographic hierarchy** doing real work?
3. Does it hold up in **dark mode** with no un-themed element?
4. Does it feel like the [same family](https://example.com/design-convention)
   as the handoff and platform surfaces?

When you've looked it over, run the feedback protocol.
