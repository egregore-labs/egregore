TUI Design System for Egregore slash commands. Use this skill when designing or modifying any command's terminal output to ensure visual consistency.

## 1. Brand Elements

### Command Headers

**`/activity` is the flagship** — it gets the full branded header with org name:
```
{ORG_NAME} EGREGORE ✦ ACTIVITY DASHBOARD
```
Read org name from `jq -r '.org_name' egregore.json`. The `✦` star is reserved exclusively for the activity dashboard and Egregore-wide branding.

**Other commands get sigil + command name only** — no org name:

| Command | Header | Sigil Meaning |
|---------|--------|---------------|
| `/activity` | `{ORG_NAME} EGREGORE ✦ ACTIVITY DASHBOARD` | The star — awareness, the full field |
| `/ask` | `? ASK` | The question — direct, clear inquiry |
| `/reflect` | `◎ REFLECTION` | The eye — looking inward, seeing clearly |
| `/handoff` | `⇌ HANDOFF` | The bridge — passing context between minds |
| `/quest` | `⚑ QUEST` | The flag — planting direction in unknown territory |
| `/todo` | `□ TODO` | The checkbox — actionable items, personal intent |

### Section Markers

Used within all TUI boxes to prefix items by category:

- `●` Action items / things needing attention
- `✓` Completed / received / done items
- `→` Navigation pointers (what to do next, entry points)
- `◦` Informational items (sessions, quests, neutral data)
- `⚑` Quests
- `⇌` Handoffs (in activity action items)
- `◎` Reflections
- `□` Todos (in activity dashboard)
- `◉` Artifacts (in handoff summaries)

## 2. Box Drawing Rules

### Line Patterns (CRITICAL)

LLMs cannot count character widths. Do NOT draw boxes freehand. Instead, produce exactly 4 line patterns. All commands use 72-char outer width (N = 70 fill characters).

1. **Top**: `┌` + 70×`─` + `┐`
2. **Separator**: `├` + 70×`─` + `┤`
3. **Content**: `│` + 2 spaces + text + pad to 68 text chars + `│`
4. **Bottom**: `└` + 70×`─` + `┘`

Characters: `┌` top-left, `─` horizontal, `┐` top-right, `│` vertical, `├` left-tee, `┤` right-tee, `└` bottom-left, `┘` bottom-right.

**Separator lines are always identical** — copy-paste the same 72-char string every time. Content lines have ONLY the outer `│` as borders. Pad every content line with trailing spaces so the closing `│` lands at position 72.

**Header separator**: always use `├───┤` between header row and content.

**Section dividers**: use `├───┤` between logical groups. No sub-boxes — never use `┌─┐`/`└─┘` inside the outer frame. LLMs cannot reliably align nested borders.

### Layout

All commands use full-width, single-column, stacked sections. No column splits — they cause truncation and render poorly. Content flows top-to-bottom with section headers separating groups.

## 3. Width Standards

- **All commands**: ~72 characters outer width
- All content lines must have matching left and right `│` borders

## 4. Content Formatting

### Session Lines (Compact)
```
Feb 07  Topic description
```
Date is always `Mon DD` format, right-padded to 6 chars. Topic follows after 2 spaces.

### Team Session Lines
```
Feb 07  oz: Topic description
```
Person name prefixed with colon separator.

### Numbered Action Items
```
[1] Description of actionable thing
[2] ⇌ Handoff from ali: blog styling (yesterday)
```
Numbers in brackets. Use section markers after the bracket for typed items.

### Status Confirmations
```
✓ Saved to knowledge/decisions/2026-02-08-...
✓ Indexed in knowledge graph
✓ Auto-saved
```

### Progress Steps
```
[1/5] ✓ Conversation file
[2/5] ✓ Index updated
[3/5] ✓ Session → knowledge graph
[4/5] ✓ Pushed + PR created
[5/5] ✓ Oz notified
```

### Linked Items
```
◦ Quest: research-agent
◦ Project: egregore
```

### Entry Points
```
→ memory/knowledge/decisions/2026-02-07-defensibility-...
→ memory/knowledge/decisions/2026-02-07-business-model.md
```

### Truncation
- Topics longer than 35 chars in column layouts get `...` suffix
- File paths: shorten to last 2 segments when possible
- Never break mid-word

## 5. Section Visibility Rules

- **Empty sections are omitted entirely** — no placeholder text, no "none yet", no empty boxes
- **Single action item still gets the action items box** — consistency over minimalism
- **Section headers only appear when their section has content**

## 6. Edge Cases

| Scenario | Handling |
|----------|----------|
| No sessions yet | Show Projects section instead (first-timer experience) |
| Neo4j down | File-based fallback, simpler layout, no columns |
| Single action item | Still show action items box |
| No team activity | Omit TEAM section |
| Very long org name | Truncate at 20 chars in activity header |
| No quests | Omit quests section |
| No PRs | Omit PRs section |
| No action items + no answers | Omit both sections, go straight to columns |

## 7. Anti-Patterns

- **Avoid sub-boxes entirely** — use `├───┤` flat dividers instead (LLMs can't count widths for nested borders)
- **Never use tables** with `│` column separator AND sub-boxes in the same section (pick one)
- **Never show empty section headers** — omit the entire section
- **Never use raw file paths** in TUI output — use `→` pointer with shortened path
- **Never break box characters** across lines — each line must have valid left/right borders
- **Never use the `✦` star** outside `/activity` header
- **Never include org name** in non-activity command headers
- **Never use emoji** in TUI boxes (sigils and markers only)

## 8. AskUserQuestion Integration

When a command's TUI includes interactive follow-up (like `/activity` numbered items):

1. Display the full TUI box first
2. Add footer text inside the box: `Type a number to act, or keep working.`
3. Use AskUserQuestion with options matching the numbered items
4. Include a "Skip" option for non-action

## 9. Color and Emphasis

Terminal output is monospace plain text. Emphasis is structural only:
- Section headers: ALL CAPS
- Sigils and markers provide visual weight
- Sub-boxes create grouping
- Indentation creates hierarchy
- No bold, italic, or color codes in the markdown instruction files
