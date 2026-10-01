---
name: me
description: "View or change the current member's Egregore profile across Claude Code, Codex, Pi, and Prime. Use for /me, 'who am I', 'call me <name>', or an explicit self email update."
---

# Egregore identity

Use the Runtime identity adapter. Account identity, actor identity,
organization membership, and provider aliases are separate concepts:

- `AccountIdentity` is the provider-independent authenticated account.
- `ActorIdentity` is the person, agent, or service acting in this session.
- `OrgMembership` supplies organization, role, and team context.
- GitHub is an optional linked provider and current transport alias. Its login
  or numeric ID is never the Egregore account or actor identity.

External people discovered during ingestion remain source-scoped identities;
this workflow never promotes them into organizational members.

## When to invoke

View or change the current member's Egregore profile across Claude Code, Codex, Pi, and Prime. Use for /me, 'who am I', 'call me <name>', or an explicit self email update.

## Show

Run once:

```bash
bash bin/person.sh show
```

The adapter resolves `ActorContext` and authorizes `read` on the current
identity before returning anything. Display the preferred name, linked
provider alias, explicitly supplied email, and aliases. Do not expose internal
IDs unless the user requests diagnostics.

## Change preferred name

For an explicit self-update, use `{arguments}` for the text after the command, or empty; single-quote the value and write any embedded single quote as `'\''`.

```bash
bash bin/person.sh set-name '{arguments}'
```

The identity adapter validates the value, preserves previous names as aliases,
authorizes `administer` on the current identity, and reconciles the same stable
account/actor/membership records. Report the returned status without exposing
raw JSON.

## Change email

Only when the authenticated user explicitly supplies their own address:

```bash
bash bin/person.sh set-email "person@example.com"
```

Never infer an email from Git configuration or unrelated source content.

## Reconcile

Use this only for onboarding, a linked-provider rename, or an identity repair:

```bash
bash bin/person.sh sync
```

The adapter owns Local/Connected reconciliation and optional derived
projections. Do not call storage providers or edit identity files directly.
A partial result means canonical Local identity is retained and the named
external reconciliation can be retried.

## Rules

- Preferred name is organization-scoped; stable account and actor IDs survive
  provider changes.
- Authentication never grants membership, retrieval scope, or action
  permission by itself.
- Do not hand-edit `.egregore-state.json`, people profiles, membership state,
  or projections.
- Emit only content-free command telemetry.
