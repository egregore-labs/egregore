---
name: announce
description: Draft, confirm, and send an Egregore group announcement from Codex when the user invokes /announce or $announce.
---

# Egregore Announce

Native Codex Egregore skill. Use this to send concise team announcements
through the existing Egregore notification path.

## Flow

1. Draft a message from the user request and current context. Keep it under
   500 characters unless the user provided exact text.
2. If the announcement references a memory artifact, publish it first and add
   the returned URL only when publication succeeds:

```bash
bash bin/publish-artifact.sh document "$FILE_PATH" --title "$TITLE" --author "$AUTHOR" --description "$DESCRIPTION"
```

Use `handoff`, `quest`, or `document` as the artifact type when appropriate.
Never fabricate a URL.

3. Follow `.claude/context/notification-consent.md`. Create a plan without
   sending:

```bash
PLAN_JSON=$(bash bin/notify.sh plan group "$MESSAGE")
```

4. Preview the plan's exact organization, all deliveries/channels, and exact
   final message. Confirm in a separate checkpoint with structured Codex
   question tooling when available; otherwise render those fields followed by:

```text
Send this announcement?
1. Send
2. Edit
3. Cancel
```

5. If the user edits, cancel the old plan, redraft, plan, and preview again.
   If they cancel, cancel the plan and stop. Only after they select Send for
   that exact preview, run:

```bash
APPROVAL_JSON=$(bash bin/notify.sh approve "$PLAN_ID" "$DIGEST" APPROVE_EXACT_NOTIFICATION)
APPROVAL_TOKEN=$(printf '%s' "$APPROVAL_JSON" | jq -r '.approval_token')
bash bin/notify.sh dispatch "$PLAN_ID" "$APPROVAL_TOKEN"
```

6. Emit telemetry in the background:

```bash
bash bin/telemetry.sh emit "command" '{"command":"announce"}' >/dev/null 2>&1 &
```

7. Confirm whether the exact approved group send succeeded.

## Rules

- The request to announce is not dispatch consent. Always use a dedicated
  exact-delivery checkpoint.
- Do not expose notification credentials.
- Use `bin/notify.sh`; do not call Telegram directly.
- Do not use Claude Code commands.
