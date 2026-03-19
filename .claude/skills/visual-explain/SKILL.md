---
name: visual-explain
description: Explain concepts visually using ASCII diagrams, flow charts, tables, and structural maps. Use when asked to explain, compare, or show how something works.
---

# Visual Explain

Explain concepts visually using ASCII diagrams, tables, flow charts, and structural maps. The visual IS the explanation — prose is secondary.

## When to invoke

Trigger phrases: "explain visually", "show me a diagram", "draw this out", "chart this", "map this", "visualize this", "show me how this works", "diagram this", "sketch this out".

Also invoke when `/visual-explain` is used directly.

## Visual vocabulary

Use the right format for the right job:

| Concept type | Visual format |
|---|---|
| Flows and pipelines | ASCII arrow diagrams (`→`, `↓`, `──▶`) |
| Architecture / components | Box diagrams with labeled connections |
| Comparisons and trade-offs | Tables with columns per option |
| Hierarchies and containment | Tree structures or nested box diagrams |
| Temporal sequences | ASCII sequence diagrams (actor columns + arrows) |
| State changes | Before/after side-by-side diagrams |
| Decision logic | Flowcharts with diamond decision nodes |

## Rules

1. **Lead with the visual.** Always produce the diagram or table FIRST. Prose comes after, if needed at all.

2. **Minimal prose.** Keep explanatory text to 1-2 sentences per diagram. The visual carries the explanation — prose only clarifies what the visual cannot.

3. **Prefer multiple small diagrams over one complex one.** Break a system into 2-3 focused visuals rather than cramming everything into a single diagram. Each diagram should have one clear point.

4. **Consistent visual language:**
   - `[ boxes ]` for components, modules, services
   - `──▶` or `→` for data flow and control flow
   - `───` for connections and relationships
   - `< diamonds >` for decisions
   - `( rounded )` for inputs/outputs
   - `│` and `─` for structure lines

5. **System explanations follow this order:**
   - Structure first (what are the parts, how do they relate)
   - Data flow second (what moves between them)
   - State changes third (how things evolve over time)

6. **Comparisons follow this order:**
   - Table first (options as columns, criteria as rows)
   - Annotate the recommended choice with a brief reason below the table

7. **Keep diagrams under 40 lines tall and 72 characters wide.** If a diagram exceeds this, split it into multiple diagrams with clear labels.

## Examples

### Flow diagram
```
  [ User Request ]
         │
         ▼
  [ Auth Middleware ] ──▶ [ 401 Unauthorized ]
         │
         ▼
  [ Route Handler ]
         │
    ┌────┴────┐
    ▼         ▼
 [ Cache ] [ Database ]
    │         │
    └────┬────┘
         ▼
  [ Response ]
```

### Comparison table
```
                 Option A        Option B        Option C
  ──────────────────────────────────────────────────────────
  Speed          Fast            Medium          Slow
  Cost           $$$             $$              $
  Complexity     High            Medium          Low
  Reliability    High            High            Medium
  ──────────────────────────────────────────────────────────
  ✓ Recommended: Option B — best balance of cost and speed.
```

### Sequence diagram
```
  Client          Server          Database
    │                │                │
    │── POST /api ──▶│                │
    │                │── INSERT ─────▶│
    │                │◀── OK ─────────│
    │◀── 201 ────────│                │
    │                │                │
```

### Hierarchy / tree
```
  egregore/
  ├── bin/            Shell scripts (graph, notify, telemetry)
  ├── skills/         Cognitive skill definitions
  │   ├── harvest/
  │   └── tui-design/
  ├── memory/         Symlink → shared memory repo
  │   ├── people/
  │   ├── handoffs/
  │   └── knowledge/
  └── .claude/
      ├── commands/   Slash command definitions
      └── skills/     Claude Code skill files
```

### Before/after
```
  BEFORE                          AFTER
  ┌──────────────────┐            ┌──────────────────┐
  │ Monolith         │            │ API Gateway       │
  │  ┌────────────┐  │            │                   │
  │  │ Auth       │  │            └─────────┬─────────┘
  │  │ API        │  │                      │
  │  │ DB         │  │              ┌───────┼───────┐
  │  │ Queue      │  │              ▼       ▼       ▼
  │  └────────────┘  │           [ Auth ] [ API ] [ Worker ]
  └──────────────────┘              │       │       │
                                    └───┬───┘       │
                                        ▼           ▼
                                     [ DB ]     [ Queue ]
```
