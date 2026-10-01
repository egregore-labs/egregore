---
name: harness-tool-names
description: Harness-specific tool names in shared skill instructions.
tier: mechanical
severity: block
surfaces: [harness]
fix: Describe the capability in plain language; use structured questions or delegation only when available and permitted in this session, with plain-text or inline fallbacks. Keep harness tool names in adapter files.
patterns:
  - '\b(?:Write|Read|Edit|MultiEdit|Bash|Glob|Grep|Task|Agent|WebFetch|WebSearch|NotebookEdit)`? tool\b'
  - '\bAskUserQuestion\b'
  - '\bEnterWorktree\b'
  - '\bExitWorktree\b'
  - '\bTodoWrite\b'
  - '`(?:AskUserQuestion|EnterWorktree|ExitWorktree|TodoWrite|NotebookEdit|MultiEdit|WebFetch|WebSearch)`'
---

Shared skills describe capabilities, not a harness's tool names. Instructions such as "use the Write tool" or "call AskUserQuestion" cannot be followed literally by every harness. Write or read the named file. Ask with a structured question when available and permitted in this session; otherwise ask in plain text. Delegate when available and permitted in this session; otherwise work inline. Create a worktree when available and permitted in this session; otherwise create a branch from the integration branch. Label harness-only steps and keep tool names in adapters. The skill audit scans raw Markdown lines, including spans and fences. Ambiguous words such as Write, Read, Edit, and Bash require a following "tool"; ordinary capability words and script paths remain valid.

## Fails

- Use the Write tool to save the file.
- Call AskUserQuestion before continuing.
- Call EnterWorktree for this task.
- Call ExitWorktree when finished.
- Track progress with TodoWrite.

## Passes

- Write the file at tmp/result.json.
- Read `tmp/x.json` before continuing.
- Edit the file at tmp/result.json.
- Create a task and ask an agent to review it.
- Run `bin/agent.sh` and delegate to the loom-executor agent when available and permitted in this session; otherwise work inline.
- Run the script with `bash`.
- Authorize `read` on the identity.
- Offer `Save`, `Edit`, or `Skip` as choices.
