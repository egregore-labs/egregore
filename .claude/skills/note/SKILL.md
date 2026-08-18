---
name: note
description: "Use when the user says 'jot this down', 'note to self', 'just thinking out loud', or 'park this thought' — saves a private personal note, never shared or pushed until explicitly promoted."
---

Save a personal note. Private by default — never shared, never pushed. You choose what to share later.

## When to invoke

User says: "jot this down", "note to self", "just thinking out loud", "park this thought", "scratch pad", "write this down", "leave notes"
Not this: insight is ready to share → `/reflect` · want deep analysis → `/deep-reflect`

Arguments: $ARGUMENTS

## Two Modes

| Invocation | Mode |
|---|---|
| `/note` | **Capture** — prompts for what to save |
| `/note [content]` | **Quick** — saves directly |
| `/note share [title]` | **Share** — promotes a personal note to shared memory |
| `/note list` | **List** — shows all personal notes |

## Design principle

Everything in `memory/` is shared. Everything in `.egregore/notes/` is yours. This command writes to your personal space. When you're ready to share, you explicitly promote — the system never pushes personal notes.

This is the save → share pipeline. Saving is frictionless. Sharing is a deliberate act.

## Capture Mode (`/note` or `/note [content]`)

### Step 1: Determine content

**If no arguments:**
Ask one question via AskUserQuestion:

```
question: "What do you want to capture?"
header: "Note"
options:
  - label: "This session"
    description: "Summarize what happened in this conversation so far"
  - label: "A thought"
    description: "Something on your mind — rough, half-baked, anything"
  - label: "A retrospective"
    description: "Reflect on how today went — what worked, what didn't"
```

**If arguments provided:** Use them as the content. Skip the question.

**If "This session" selected:** Read the conversation context and produce a concise personal summary — what happened, what you worked on, what you're thinking. Not a handoff (those are for others). This is for future you.

### Step 2: Write the note

Generate a slug from the content: lowercase, hyphens, max 40 chars.

File path: `.egregore/notes/{YYYY-MM-DD}-{slug}.md`

Ensure `.egregore/notes/` exists (create silently if not).

Write the file using the Write tool (it's a local file, not in memory/):

```markdown
# {Title}

**Date**: {YYYY-MM-DD}
**Type**: {thought | session | retrospective | journal}

{Content — the user's words, expanded if needed but preserving their voice}
```

Keep it minimal. No Neo4j. No git operations. No push. Just a file.

### Step 3: Confirmation

Short confirmation, no TUI box needed:

```
  ✎ Saved to .egregore/notes/{filename}
  Private — only visible in your sessions.
  /note share "{title}" to contribute to shared memory.
```

## Share Mode (`/note share [title]`)

### Step 1: Find the note

If title provided, fuzzy-match against filenames in `.egregore/notes/`.
If no title, list recent notes and let the user pick via AskUserQuestion (max 4 options from most recent notes).

If no notes exist: "No personal notes yet. Use `/note` to capture something first."

### Step 2: Read the note

Read the matched file. Show a preview (first 5 lines of content).

### Step 3: Choose destination

Ask via AskUserQuestion:

```
question: "Where should this go?"
header: "Share to"
options:
  - label: "Knowledge"
    description: "Save as a decision, finding, or pattern in memory/knowledge/"
  - label: "Handoff"
    description: "Turn this into a handoff to someone specific"
  - label: "Artifact"
    description: "Save as an artifact in memory/artifacts/"
```

### Step 4: Promote

Based on the user's choice:

**Knowledge:** Follow the `/reflect` quick mode flow — auto-classify (decision/finding/pattern), create the file in `memory/knowledge/{category}s/`, create Neo4j Artifact node, run `/save` flow.

**Handoff:** Ask who to hand off to, then follow the `/handoff` flow with the note content as the session summary.

**Artifact:** Follow the `/add` flow with the note content.

After sharing, append a line to the original note:

```markdown

---
Shared: {YYYY-MM-DD} → memory/knowledge/{path}
```

This marks it as promoted without deleting the personal copy.

### Step 5: Confirmation

```
  ✎ Note shared → memory/knowledge/{category}s/{filename}
  ✓ Graphed · saved · pushed
  Your personal copy kept in .egregore/notes/
```

## List Mode (`/note list`)

List all files in `.egregore/notes/`, sorted by date (newest first).

Format:
```
  ✎ Personal Notes

  2026-02-10  feb-10-session-report          thought
  2026-02-10  command-compositionality-idea   thought
  2026-02-09  late-night-ontology-notes       session

  3 notes · /note share "<title>" to contribute
```

Read frontmatter to get type. If directory is empty: "No personal notes yet."

## Edge cases

| Scenario | Handling |
|----------|----------|
| `.egregore/notes/` doesn't exist | Create it silently |
| File collision (same slug, same date) | Append `-2`, `-3` etc. |
| `/note share` with no notes | "No personal notes yet. Use `/note` to capture something first." |
| Fuzzy match finds multiple notes | Show top 3 matches via AskUserQuestion |
| Memory symlink missing | Share mode errors: "Run /setup first — memory not linked." Capture mode still works (personal notes don't need memory/) |
| Very long content | Truncate preview in list mode at 60 chars. Full content always preserved in file. |
