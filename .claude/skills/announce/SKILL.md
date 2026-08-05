Send an announcement to the Telegram group. Drafts a message, shows a preview for approval, then sends.

## When to invoke

User says: "announce", "tell the team", "send to the group", "notify everyone", "let everyone know"
Not this: notify one person → prepare a direct notification proposal · handoff → `/handoff`

Topic: $ARGUMENTS

## What to do

### Step 1: Draft the message

If `$ARGUMENTS` is provided, use it as the topic and draft a concise announcement (2-5 lines). Pull context from the conversation — what just happened, what changed, what the team should do.

If no arguments, ask: "What should I announce?"

**Message guidelines:**
- Lead with what changed (feature, fix, decision, merge)
- Include the PR number or branch if relevant
- End with an action if needed ("Run /update to get it", "Review PR #N", etc.)
- Keep it under 500 chars (chat readability)
- No emojis unless the user's draft uses them

### Step 2: Publish artifact (if relevant)

If the announcement references a document, handoff, quest, or knowledge artifact from `memory/`, publish it now so the final message includes a clickable link with OG preview.

**Detect:** Check if the conversation produced or references a specific file in `memory/` (handoffs, knowledge, quests). If so, publish it:

```bash
ARTIFACT_URL=$(bash bin/publish-artifact.sh document "$FILE_PATH" \
  --title "$TITLE" \
  --author "$AUTHOR" \
  --description "$ONE_LINE_DESCRIPTION" 2>/dev/null)
```

Use the appropriate type: `handoff`, `quest`, or `document` (for knowledge files).

- **If publish succeeds**: insert the returned live URL into the message draft.
- **If publish fails**: send the message without a link. Do NOT make up a URL.

**Never fabricate artifact URLs.** Only use URLs returned by `publish-artifact.sh`.

### Step 3: Plan, preview, and confirm

Follow `.claude/context/notification-consent.md`. Create the group plan only
after the artifact URL and message are final:

```bash
PLAN_JSON=$(bash bin/notify.sh plan group "$MESSAGE")
```

Confirm via AskUserQuestion. Do NOT print the draft as text before the tool call — the harness hides text that precedes a tool call, so a draft "shown" that way is never seen and the user approves blind. The `preview` field is the only carrier the user actually sees:

```
header: "Send"
question: "Send this exact notification?"
options:
  - label: "Send"
    description: "Send once to the listed group channels"
  - label: "Edit"
    description: "I want to change the wording"
  - label: "Cancel"
    description: "Do not send anything"
```

**MANDATORY:** put the organization, every delivery/channel, and exact final
message in the `preview` field of the "Send" option. Without all three, there
is no valid consent.

**If "Send"** → proceed to Step 4 using that plan's id and digest.
**If "Edit"** → cancel the plan, ask what to change, redraft, plan, and preview again.
**If "Cancel"** → cancel the plan and stop without sending.
**If user types custom text** → cancel the plan, use their text, create a new plan, and preview again.

### Step 4: Approve and dispatch once

```bash
APPROVAL_JSON=$(bash bin/notify.sh approve \
  "$PLAN_ID" "$DIGEST" APPROVE_EXACT_NOTIFICATION)
APPROVAL_TOKEN=$(printf '%s' "$APPROVAL_JSON" | jq -r '.approval_token')
bash bin/notify.sh dispatch "$PLAN_ID" "$APPROVAL_TOKEN"
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

- Always show the organization, every channel, and exact final message in a
  separate notification checkpoint.
- The user's request to announce is not consent to dispatch.
- Keep messages concise — group chat, not an essay
- If the user provides the exact message text in quotes, use it verbatim
- Never fabricate artifact URLs — only use URLs returned by `publish-artifact.sh`
