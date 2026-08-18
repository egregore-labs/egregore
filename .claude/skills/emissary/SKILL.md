---
name: emissary
description: Compose, send, or run an Egregore emissary — portable handoff v1 artifacts with server-rendered HTML at egregore.xyz. Use for `/emissary`, "make/send/run an emissary", or when a user pastes an `egregore.xyz/emissary/e/<id>` link.
---

Topic: $ARGUMENTS

## When to invoke

User says: "/emissary", "make an emissary", "let's make an emissary", "send an emissary to <name>", "create an emissary", "run this emissary", or pastes an `egregore.xyz/emissary/e/<id>` link.

Not this: user wants a **team session-handoff** (recap of what happened this session, addressed to a teammate, indexed in Neo4j, posted to Telegram) → that's `/handoff`. The two are siblings, not competitors: `/handoff` is the internal recap; `/emissary` is the portable, executable capsule.

## Relationship to the framework skill

The framework-level `egregore-emissary` skill (installed via `npx egregore-emissary install`, lives at `~/.claude/skills/egregore-emissary/SKILL.md`) owns the compose / publish / run flow end-to-end. This project skill is a **thin Egregore overlay** on top of it:

1. **Delegate the compose/run** to the framework skill — its full procedure (interview via AskUserQuestion, shape decision, answers JSON, self-check, `npx egregore-emissary@latest new --answers ...`) is the source of truth. Do not duplicate it here. Follow it.
2. **Add the Egregore overlay** — see Step 6 below — once the framework skill has produced a URL.

If the framework skill is missing (path above does not exist), tell the user: "the `egregore-emissary` skill isn't installed — run `npx egregore-emissary@latest install`" and stop. Do not try to reconstruct it from memory.

## Intent routing

| Signal | Intent | Branch |
|---|---|---|
| Pasted `egregore.xyz/emissary/e/<id>` link, or "run this", "open this packet" | **run** | follow the framework skill's "Run an emissary" procedure. Stop after that — no Egregore overlay on runs. |
| "make / create / compose an emissary", "let's make an emissary", "send an emissary to <name>", bare `/emissary` | **create** | follow the framework skill's "Create an emissary" procedure for steps 1–4, then do **Step 6** below. |
| "enact my {name} emissary", "run my starred {name}", "list my stars", "what have I starred", or a pasted `@{handle}/{slug}` address | **enact starred** | the platform runtime-addressability verb (spec §2.5) — see "Enact a starred emissary" below. Stop after that — no overlay on runs. |

## Enact a starred emissary (platform §2.5)

Star on the web, enact in the terminal. The chain: starred list → resolve
per star mode → fetch `/raw` → normal enactment.

Base URL: `https://egregore.xyz` (override with `EMISSARY_WEB_ORIGIN` if
set — smoke rigs point this at a local stub server).

1. **Token.** Read the auth token from `~/.egregore/emissary-config.json`
   (`.auth_token` via `jq -r`, or `EMISSARY_CONFIG_PATH` if set). Never
   print it — it is a credential. If absent: "no emissary identity on
   this machine — run `npx egregore-emissary@latest install`" and stop.

2. **Star list.** `GET {base}/api/v1/platform/stars` with
   `Authorization: Bearer <token>`. Cache the response to
   `~/.egregore/platform/stars-cache.json` (best-effort) so "list my
   stars" works offline; refresh the cache on every successful fetch.
   On "list my stars" intent: render address · topic · mode · version
   per star and stop.

3. **Match by name.** Resolve the user's phrase against each star's
   `slug`, `address`, and `topic` (case-insensitive substring is fine —
   e.g. "deep research" matches `@cem/deep-research`). One match →
   proceed. Several → AskUserQuestion with the candidate addresses.
   None → show the starred addresses, stop.

4. **Resolve per mode.** The endpoint already resolved for you:
   - `mode: "pin"` → `resolved_id` is the exact version evaluated at
     star time (supply-chain-safe default; never silently follow a
     moved head).
   - `mode: "follow"` → `resolved_id` is the current head. If
     `updated_since_star` is true, STOP and re-consent before enacting:
     "**@{owner}/{slug} has updated since you starred it** (you
     evaluated v{evaluated}, head is now v{current}). Enact the new
     version?" — AskUserQuestion: Enact new head / Show what changed
     (`GET {base}/api/v1/platform/@{owner}/{slug}/versions`) / Cancel.
     Only proceed on explicit yes.

5. **Fetch + enact.** `GET {base}/emissary/e/{resolved_id}/raw` with the
   bearer token. From here it is a normal run: follow the framework
   skill's "Run an emissary" procedure with the fetched artifact (frame,
   intake, confirm, execute, hand over, donate). No Egregore overlay.

## Step 0: Identity

Derive the lowercase author handle from `git config user.name` (first word, lowercased). Used for the memory pointer filename in Step 6.

In connected mode, you may also need the display name — read `memory/people/<handle>.md` first line (`# Display Name`).

## Steps 1–5: Framework skill

Run the framework `egregore-emissary` skill's procedure for the chosen intent:

- **run** → its "Run an emissary" section (fetch, frame, intake, confirm, execute, hand over, donate). Then **stop** — no overlay.
- **create** → its "Create an emissary" section (interview → decide shape → compose answers JSON → self-check → `npx egregore-emissary@latest new --answers <file>`). Once you have the returned `egregore.xyz/emissary/e/<id>` link, continue to Step 6.

The framework skill is comprehensive. Do not improvise around it.

## Step 6: Egregore overlay (create flow only)

After the framework skill returns the published URL, do two small things — both fire-and-forget, neither gates the user's experience.

### 6a: Memory pointer

Write a one-screen pointer file so the team can see this emissary on `/activity` and so memory carries a record without re-hosting the artifact.

Path: `memory/handoffs/outbound/YYYY-MM-DD-<author>-<slug>.md`

Slug rules: lowercase, alphanumeric and hyphens only, derived from the emissary `topic` field, truncated at 60 chars. If a file exists at that path, append `-2`, `-3`, etc.

Body:

```markdown
# Emissary: <topic>

**Date**: YYYY-MM-DD
**Author**: <Display Name>
**Kind**: <kind>
**Distribution**: <public | person>
**Recipients**: <comma-separated emails, or "public link">
**URL**: <egregore.xyz/emissary/e/<id>>

## Claim

<one sentence — what running this produces>

## Ask

<one sentence, or omitted if no ask>

## Summary

<one paragraph from the artifact's summary field>
```

Omit any section that is empty.

Then prepend a one-line entry to `memory/handoffs/index.md`:

```
- YYYY-MM-DD — <author>: emissary — <topic> → <url>
```

Commit and push:

```bash
cd memory && git add handoffs/outbound/ handoffs/index.md && \
  git commit -m "emissary pointer: <topic>" >/dev/null 2>&1 && \
  git pull --rebase --no-edit >/dev/null 2>&1 && \
  git push >/dev/null 2>&1 &
```

Detached. Do not block the user on the push.

### 6b: Neo4j index (connected mode only)

Mode detection:

```bash
MODE=$(jq -r '.mode // "local"' egregore.json 2>/dev/null)
```

If `MODE == "connected"`, fire-and-forget a minimal index call:

```bash
SESSION_ID="$(cat .egregore-session-id 2>/dev/null)"
bash bin/graph.sh query "
  MERGE (e:Emissary {id: \$emissaryId})
  ON CREATE SET e.created = datetime(), e.topic = \$topic, e.kind = \$kind, e.url = \$url
  WITH e
  MATCH (p:Person {github: \$author})
  MERGE (p)-[:SENT_EMISSARY]->(e)
  WITH e
  OPTIONAL MATCH (s:Session {id: \$sessionId})
  FOREACH (_ IN CASE WHEN s IS NOT NULL THEN [1] ELSE [] END |
    MERGE (s)-[:PRODUCED]->(e))
  RETURN e.id" >/dev/null 2>&1 &
```

Pass `emissaryId`, `topic`, `kind`, `url`, `author`, `sessionId` via the standard `bin/graph.sh` parameter mechanism (whatever the project uses for $-substituted Cypher; if unsure, read another graph-using script — `bin/index-handoff.sh` is the canonical example).

If `bin/graph.sh` is unavailable, skip silently. Local mode skips entirely. This is best-effort; the artifact and the memory pointer are the source of truth.

## Step 7: Render the receipt

After the framework skill has handed back the URL and the overlay has fired, render one acknowledgment to the user. Same boundary style as `/handoff` — 72-char wide box, four line patterns:

```
┌──────────────────────────────────────────────────────────────────────┐
│  ⇌ EMISSARY SENT                                  {Author} · {MMM DD}  │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Topic: {topic}                                                      │
│  Kind:  {kind}                                                       │
│  To:    {recipient(s) or "public link"}                              │
│                                                                      │
│  {claim, wrapped at ~64 chars}                                       │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  ✓ published · pointer saved{ · graphed if connected}                │
└──────────────────────────────────────────────────────────────────────┘
```

Below the box, one line:

```markdown
[open emissary →]({url})
```

Share the bare page link — not a `/raw` URL or a "Run this … packet" prompt. With the emissary skill installed, pasting the link is enough; this de-alarmed handover (see the data-room variant-A flow in `bin/build-sealed-dataroom.mjs`) avoids tripping a recipient agent's prompt-injection alarms.

If natural, add one short sentence of sign-off — what the recipient should do next, or "shared publicly — anyone with the link can run it."

## Edge cases

| Scenario | Handling |
|---|---|
| Framework skill missing | Stop, tell the user to run `npx egregore-emissary@latest install`. Do not reimplement. |
| User has no emissary identity (publish fails with auth error) | Stop, surface the framework skill's error verbatim. Do not run `emissary install` for them — it's their identity. |
| `npx egregore-emissary` returns non-zero | Surface stderr, do not write the memory pointer (no URL = nothing to point at). |
| Memory push fails in 6a | Stay silent. The file is on disk locally; next `/save` or `/handoff` pushes it. |
| Connected-mode graph query fails | Silent. The pointer file is the source of truth. |
| User wants to receive ↦ a link is in $ARGUMENTS | Skip Step 6 entirely. Runs don't get an overlay. |

## Why this is two skills, not one merged with /handoff

- `/handoff` is **team-internal session recap**: indexed Session node, Telegram team ping, addressed to a teammate or self, repo state captured, auto-PR'd memory. Receivers are inside the org.
- `/emissary` is **portable executable capsule**: handoff/v1 JSON-LD artifact, server-rendered at egregore.xyz, optionally addressed to an external email, may or may not relate to a team session at all.

A session-handoff that *also* needs to be sent externally → run `/handoff` first, then `/emissary` separately. Don't try to bundle them.
