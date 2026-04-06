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

### Step 3: Publish artifact (if relevant)

If the announcement references a document, handoff, quest, or knowledge artifact from `memory/`, publish it first so the Telegram message includes a clickable link with OG preview.

**Detect:** Check if the conversation produced or references a specific file in `memory/` (handoffs, knowledge, quests). If so, publish it:

```bash
ARTIFACT_URL=$(bash bin/publish-artifact.sh document "$FILE_PATH" \
  --title "$TITLE" \
  --author "$AUTHOR" \
  --description "$ONE_LINE_DESCRIPTION" 2>/dev/null)
```

Use the appropriate type: `handoff`, `quest`, or `document` (for knowledge files).

- **If publish succeeds**: `ARTIFACT_URL` contains the live URL (e.g. `https://egregore.xyz/view/curvelabs/U8mscr78Vp0`). Insert it into the message draft.
- **If publish fails**: `ARTIFACT_URL` is empty — send the message without a link. Do NOT make up a URL.

**Never fabricate artifact URLs.** Only use URLs returned by `publish-artifact.sh`.

### Step 4: Send

```bash
bash bin/notify.sh group "$MESSAGE" 2>/dev/null
```

Confirm: `✓ Announced to the group.`

### Step 5: Telemetry

```bash
bash bin/telemetry.sh emit "command" '{"command":"announce"}' 2>/dev/null &
```

## Examples

### Simple announcement (no artifact)

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

### Announcement with artifact link

```
> /announce telemetry architecture doc is ready

  Publishing artifact...
  ✓ Published: https://egregore.xyz/view/curvelabs/U8mscr78Vp0

  Preview:

  Telemetry architecture doc is up (PR #485)

  Full system reference — data flow, event types,
  flush modes, DB schema, admin queries.

  https://egregore.xyz/view/curvelabs/U8mscr78Vp0

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
- Never fabricate artifact URLs — only use URLs returned by `publish-artifact.sh`
