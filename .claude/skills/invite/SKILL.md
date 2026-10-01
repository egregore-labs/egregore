---
name: invite
description: "Invite someone to this Egregore — repository access plus a setup link when Connected. Use for /invite <username>, 'invite <username>', or 'add <username> to the org'; not member removal."
---

# Egregore invite

Invite one future organization member through the Egregore Runtime. The
GitHub username is a linked-provider alias used by today's access transport;
it is not an Egregore account, actor, or membership identifier.

## When to invoke

Invite someone to this Egregore — repository access plus a setup link when Connected. Use for /invite <username>, 'invite <username>', or 'add <username> to the org'; not member removal.

## Input

Require one GitHub username. If it is missing, show and stop:

```text
Usage: /invite <github-username>

Example: /invite newuser
```

## Execute

Use the supplied GitHub username as `{provider_username}`; quote placeholders
in single quotes when you use them in a command, and write any single quote
inside a value as `'\''`. Run exactly one invitation transaction and save its
JSON receipt:

```bash
mkdir -p tmp
```

```bash
bash bin/invite.sh '{provider_username}' > tmp/invite-receipt.json
```

Read the fields needed to render the receipt:

```bash
jq -r '{status, provider_username, org_name, provider_status, memory_status, invite_url, join_command, group_link, manual_access_url, warnings} | to_entries[] | "\(.key): \(.value)"' tmp/invite-receipt.json
```

Use each printed field as its correspondingly named placeholder below.

The adapter resolves `ActorContext`, keeps `AccountIdentity`, `ActorIdentity`,
and `OrgMembership` separate, authorizes `ADMINISTER` before external effects,
and selects the current GitHub or Connected control-plane transport. It owns
credentials, repository grants, the provisional canonical invitation record,
path-scoped Git provenance, and sanitized error mapping. Do not call GitHub,
the Egregore API, graph, storage providers, or Git directly.

Connected service permission denials are authoritative. Explain that an
organization admin must invite the person and show `manual_access_url` when
the receipt contains one. Never infer permission from a GitHub username.

## Render

For an accepted Connected invite with `invite_url`:

```text
Inviting {provider_username} to {org_name}...

  Repository access: {provider_status}
  Memory access:     {memory_status}
  Invite link:       created

Share this link with {provider_username}:

  {invite_url}

They'll authenticate, accept the access invitation, and receive
the install command.
```

For an accepted Local invite:

```text
Invited {provider_username} to {org_name}.

  Repository access: {provider_status}
  Memory record:     {memory_status}

Tell them to run:

  {join_command}
```

Append the returned group link when present. Render warnings truthfully and
use the returned manual access URL for failed repository grants. Never show
raw JSON, tokens, request bodies, or internal identity IDs.

## Optional direct notification — separate consent

The invite action never authorizes a message. Only when a direct destination
exists and the user wants Egregore to deliver the link, create a fresh
actor-bound notification plan for this exact message:

```text
You've been invited to {org_name} on Egregore! Join here: {invite_url-or-command}
```

Write it to `tmp/invite-message.md`, make the file
mode 0600, then run:

```bash
chmod 600 tmp/invite-message.md
```

```bash
bash bin/notification.sh plan --kind send \
  --recipient '{provider_username}' --message-file tmp/invite-message.md > tmp/invite-plan.json
```

```bash
jq -r '.plan_id, .digest' tmp/invite-plan.json
```

Use the printed values as `{plan_id}` and `{digest}`, respectively, for the
notification Runtime's approve/cancel commands. Read the preview fields:

```bash
jq -r '.org, .recipient, .channels, .deliveries, .message' tmp/invite-plan.json
```

Show the exact organization, recipient, every channel, and message in a
dedicated **Send / Edit / Cancel** checkpoint. Dispatch only after fresh exact
approval using the notification Runtime's approve/dispatch commands. Never
fall back from direct delivery to a group, reuse old approval, retry from a
detached task, or treat sharing the invite link as notification consent.

## Rules

- Local works without graph or Connected infrastructure.
- Connected preserves the existing seven-day setup-link behavior.
- An invite is provisional authority to create a future membership. Do not
  mint an AccountIdentity, ActorIdentity, or OrgMembership for the invitee.
- Existing onboarded profiles are never overwritten by an invitation stub.
- Notification consent and membership-invite authorization are separate.
