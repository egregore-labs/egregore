---
name: announce
description: "Draft, preview, and explicitly send an Egregore group announcement. Use for /announce, telling the team something, or notifying everyone—not a direct message or structured handoff."
---

# Egregore announce

Draft one concise group message. The request authorizes drafting, never
dispatch or artifact publication. Reuse sufficient `EGREGORE_ORG_CONTEXT_V1`;
do not repeat organizational retrieval merely to decorate the message.

Preserve quoted wording exactly. Otherwise use 2–5 lines: what changed, the
relevant branch/artifact when already authorized, and the requested action.
Notification consent and publication consent are separate. Never publish a
referenced artifact automatically; publication is a separate
`SHARE` workflow with its own source/destination approval.

Write the final draft to `tmp/announce-message.md`, then
make the file private and prepare one actor-bound Runtime plan:

```bash
chmod 600 tmp/announce-message.md
```

```bash
bash bin/notification.sh plan --kind group --message-file tmp/announce-message.md > tmp/announce-plan.json
```

Read the plan's identifier and digest:

```bash
jq -r '.plan_id, .digest' tmp/announce-plan.json
```

Use the printed values as `{plan_id}` and `{digest}`, respectively; quote
placeholders in single quotes when you use them in a command, and write any
single quote inside a value as `'\''`.

Read the exact preview fields from the saved plan:

```bash
jq -r '.org, .recipient, .channels, .deliveries, .message' tmp/announce-plan.json
```

Show one dedicated **Send / Edit / Cancel** checkpoint containing the exact
organization, group, every delivery/channel, and final message returned by the
plan. Edit cancels the old plan before creating a new one. Cancel calls:

```bash
bash bin/notification.sh cancel '{plan_id}'
```

Only a fresh **Send** response for that exact checkpoint authorizes:

```bash
bash bin/notification.sh approve \
  '{plan_id}' '{digest}' APPROVE_EXACT_NOTIFICATION --out tmp/announce-approval.json
```

Use `{plan_id}` from the saved plan; the adapter reads the private approval
receipt from `tmp/announce-approval.json` without exposing its credential:

```bash
bash bin/notification.sh dispatch '{plan_id}' --approval-file tmp/announce-approval.json
```

Report the returned delivery receipt. Never retry from old approval, change a
destination, or fall back to another channel. Local instances without a
notification capability stop after preview and return the text for manual use.
The Runtime service owns ActorContext authorization, exact-plan binding,
transport, and content-free telemetry.

## When to invoke

Draft, preview, and explicitly send an Egregore group announcement. Use for /announce, telling the team something, or notifying everyone—not a direct message or structured handoff.
