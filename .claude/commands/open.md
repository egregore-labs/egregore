Open and display a file's full content.

Never summarize — show everything verbatim.

## When to invoke

User says: "open", "read", "show me", "display", "let me see", "pull up", "what does [file] say", "open the handoff", "read the decision", "show the artifact"
Not this: user wants a summary → just answer normally · user asks "what's in [file]" as a question → answer from context

Arguments: $ARGUMENTS (file path, or a fuzzy description like "cem's handoff about strategy")

## Execution

### 1. Resolve the file path

If `$ARGUMENTS` is an exact path (absolute or relative), use it directly.

If it's a fuzzy description, search these locations in order:

| Intent pattern | Search location |
|---|---|
| "handoff" + person/topic | `memory/handoffs/` (newest first — check monthly dirs like `2026-02/`) |
| "decision" + topic | `memory/knowledge/decisions/` |
| "pattern" + topic | `memory/knowledge/patterns/` |
| "artifact" + topic | `memory/artifacts/` |
| person's file | `memory/people/` |
| anything else | Glob from project root |

**Search strategy**: Use Glob to list candidates, then pick the best match by recency + keyword overlap. If multiple matches, show a numbered list and let the user pick — do NOT guess.

### 2. Read the file

Use the Read tool to load the full file content.

### 3. Display verbatim

Output the **entire file content** in a fenced code block with the appropriate language tag:

````
```markdown
[full file content — every line, no omissions]
```
````

After the code block, add exactly one line:

```
{filename} · {line_count} lines
```

### 4. Done

Do not add commentary, analysis, summary, or suggestions after displaying the file. The user asked to read — let them read. If they want analysis, they'll ask.

## Rules

- **NEVER summarize, paraphrase, excerpt, or editorialize.** This is the entire point of this command.
- **NEVER truncate.** Show every line. If the file is very long (500+ lines), still show it all but add a note at the top: `(Long file — {n} lines)`.
- **ALWAYS use a fenced code block.** Markdown files use ` ```markdown `, YAML uses ` ```yaml `, etc.
- If the file doesn't exist, say so clearly. Don't guess alternatives unless asked.
- If multiple files match a fuzzy query, list them and ask — never silently pick one.
