Send an announcement to the Telegram group. Drafts a message, shows a preview for approval, then sends.

## When to invoke

User says: "announce", "tell the team", "send to the group", "notify everyone", "let everyone know"
Not this: notify one person → `bash bin/notify.sh send` · handoff → `/handoff`

Topic: $ARGUMENTS

## What to do

### Step 1: Draft the message

If `$ARGUMENTS` is provided, use it as the topic and draft a concise announcement (2-5 lines). Pull context from the conversation — what just happened, what changed, what the team should do.

If no arguments, ask: "What should I announce?"

**Message guidelines:**
- Lead with what changed (feature, fix, decision, merge)
- Include the PR number or branch if relevant
- End with an action if needed ("Run /update to get it", "Review PR #N", etc.)
- Keep it under 500 chars (Telegram readability)
- No emojis unless the user's draft uses them

### Step 2: Preview and confirm

Show the draft and use AskUserQuestion:

```
header: "Announce"
question: "Send this to the group?"
options:
  - label: "Send"
    description: "Post to Telegram group now"
  - label: "Edit"
    description: "I want to change the wording"
```

Use the `preview` field to show the exact message that will be sent.

**If "Send"** → proceed to Step 3.
**If "Edit"** → ask what to change, redraft, preview again.
**If user types custom text** → use their text as the message, preview again.

### Step 3: Send

```bash
bash bin/notify.sh group "$MESSAGE" 2>/dev/null
```

Confirm: `✓ Announced to the group.`

### Step 4: Telemetry

```bash
bash bin/telemetry.sh emit "command" '{"command":"announce"}' 2>/dev/null &
```

## Example

```
> /announce greeting redesign is live

  Preview:

  New greeting redesign is live (PR #302 by Kaan)

  Variation D: org/repo identity first, team activity
  center, compact health footer.

  Run /update to get it.

  Send this to the group?
  1. Send
  2. Edit

> 1

  ✓ Announced to the group.
```

## Rules

- Always preview before sending — never send without confirmation
- Keep messages concise — Telegram group, not an essay
- If the user provides the exact message text in quotes, use it verbatim
