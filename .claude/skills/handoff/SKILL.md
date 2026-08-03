Address the current session context to a teammate or future you. `/handoff` is
pure capture; pending-work triage belongs to `/activity`.

Topic: $ARGUMENTS

**Auto-saves.** No need to run `/save` after.

## When to invoke

User says: "leave a handoff", "pass this to [name]", "hand off to [name]"
Not this: personal session closure → `/wrap` · pending handoffs → `/activity` · push and keep working → `/save`

**Scope:** `/handoff` is the **team session-handoff** — internal recap addressed to a teammate or future-you, indexed in Neo4j, written to `memory/handoffs/`, and auto-PR'd to the configured base branch. It may prepare an external notification, but that notification is a separate human-approved action. It is NOT a portable capsule.

**Portable, executable capsules** — the kind you share with someone outside the team via an `egregore.xyz/emissary/e/<id>` link — live in `/emissary`. If the user pastes such a link, asks to "make/send/run an emissary", or wants capsule lifecycle (receive, reply, run), route to `/emissary` and stop. Do not handle capsules here.

## Disambiguation

- "Show me my handoffs" → team handoffs (`/activity`). For capsules sent externally, that's `/emissary` territory.
- "I'm done", "wrap this up" → `/wrap`.
- "hand off to alice", `/handoff <topic>` → AUTHOR flow below.
- "Let's make an emissary", "send an emissary to alice", pasted `egregore.xyz/emissary/e/<id>` → `/emissary`.

## Mode detection

```bash
MODE=$(jq -r '.mode // "connected"' egregore.json 2>/dev/null)
```

**Local mode** (`mode === "local"`): graph queries and DM-style notifications are unavailable. A recipient-less group notification can be proposed when `telegram_chat_id` is set, but an addressed DM never falls back to the group. **Nothing is uploaded and there is no shareable URL** — the handoff is written to `memory/handoffs/` and stays there. Without an org API key the only publishing route is a public, unauthenticated relay (anyone with the link can read it, 7-day TTL), and that is off unless the instance ran `bin/settings.sh relay on`. Never tell the user their handoff was published when `publishStatus` is `relay-off`.

**Connected mode**: full feature set — Neo4j indexing, today's artifacts query, DM notifications, branded permanent artifact URLs, PR-number backfill.

## Execution model

Mechanical work enters through `bin/capture-run.sh --mode addressed` in a
single Bash call. The shared capture engine delegates rich publishing and
notification planning to the addressed worker while preserving the same canonical
capture fields used by `/wrap` and SessionEnd.

**No per-step progress chatter.** The Bash tool block IS the progress indicator. No `[1/5] ✓ Conversation file` lines.

**No raw JSON.** Parse the addressed compatibility result
(`$TMPDIR/handoff-run-result.json`); only render the rich TUI card as text.
Never echo raw JSON back to the user.

**Suppress raw output.** All `bin/graph.sh` and `bin/notify.sh` calls from this
skill MUST redirect stdout to `/dev/null` or capture in a variable. Only show
formatted progress lines or the final card.

## Step 0: Identity + team directory

```bash
git config user.name
```

Derive author handle: **lowercase first word** of git user.name (e.g. "Alice Smith" → "alice", "Oguzhan" → "oguzhan"). Do NOT pass a mixed-case handle — the script uses it verbatim in filenames and commit messages.

**Team members — always from the filesystem**, regardless of mode. `memory/people/*.md` is the source of truth for both the GitHub handle and the display name:

```bash
for f in memory/people/*.md; do
  [ -f "$f" ] || continue
  github=$(basename "$f" .md)
  display=$(head -1 "$f" | sed 's/^# //')
  echo "$github|$display"
done
```

- **Filename** (minus `.md`) = GitHub handle.
- **First line** (`# Display Name`) = the name the person chose, including anything they set via `/me "call me oz"`. `/me` writes this line directly to the file and re-syncs the graph's `Person.name` to match — the file is canonical. In local mode the file is the only place it lives; in connected mode the graph mirrors it.

Match recipient case-insensitively against either. Display name wins on conflict (`/handoff to oz` should resolve even if the filename is `oguzhan.md`).

The graph has a couple more fields (`fullName`, `telegramUsername`) that /handoff doesn't use for recipient matching, so a graph round-trip here would just be ~1s of network for the same handle + display name we already have on disk. Skip it.

## Step 1: Parse arguments (create flow)

Extract from `$ARGUMENTS`:
- **Topic** — the thing being handed off (may include "to <person>" which you strip from the topic).
- **Recipient** — optional, derived from "to <name>" or "for <name>". Leave empty only if no "to" clause at all.

**"to self" / "to me" / "to myself" → recipient = author handle.** These phrases mean "DM future-me the link", not "broadcast to the group". Set `--recipient` to the author handle (lowercase first word of `git config user.name`) so notify routes as a personal DM. Strip the self-phrase from the topic.

Examples:
- `auth flow to alice` → topic: `auth flow`, recipient: `alice`
- `mcp debugging for cem to pick up` → topic: `mcp debugging`, recipient: `cem`
- `research pipeline writeup` → topic: `research pipeline writeup`, recipient: (none)
- `tui cleanup to self` → topic: `tui cleanup`, recipient: `{author handle}` (DM to author)
- `tui cleanup to myself` → topic: `tui cleanup`, recipient: `{author handle}` (DM to author)

**Recipient matching:** case-insensitive against the team directory from Step 0. Match display name OR GitHub handle. Display name wins on conflict.

**Empty arguments** → summarize the session and synthesize a topic from
conversation context. Do not inspect or triage incoming handoffs here.

**Recipient not in the team directory** → don't burn an AskUserQuestion. Proceed without `--recipient` and note it in the final card footer: `◐ {name} not in team directory — handoff saved without direct address.`

## Step 2: Classify the content, then confirm

Choose one mode before writing or rendering:

**Supplied content** — the user pasted substantial prose, supplied a document,
or approved exact wording. The supplied Markdown is authoritative. Preserve its
wording, order, headings, lists, code blocks, and links. Add only invisible
capture frontmatter with `content_mode: supplied`. Do not create a house-kit
JSON, infer attachments, add repo state, or add session artifacts unless the
user asks. Preview it with:

```bash
node packages/egregore-artifacts/bin/cli.js handoff "$BODY_FILE" \
  --verify-fidelity
```

**Generated content** — the user supplied only a topic or fragmentary notes.
Compose it into the house-kit as described below.

A handoff renders through the **shared composer** (the same one emissaries use), so it comes out looking like a flagship artifact — the way cem's Decision Surface does — **not a wall of prose**. The beauty comes from *composing*: you read the session and **choose a component per section**. A dumb markdown→render converter can't invent structure; you can. This is the whole difference between "themed" and "beautiful."

You produce **two things**, both in your head:

**1. The house-kit render spec — a JSON (this is the beautiful artifact).**
```json
{
  "kind":"handoff", "kicker":"Handoff", "topic":"<topic>",
  "claim":"<one line — what this handoff is>",
  "sourceMap":{"Briefing":"briefing","Key Decisions":"decisions","Current State":"current-state","Open Threads":"open-threads","Next Steps":"next-steps","Entry Points":"entry-points"},
  "chips":[{"text":"From <author>"},{"text":"For <recipient>"},{"text":"<date>"},{"text":"<status>","tone":"brass"}],
  "highlights":[{"v":"<stat>","l":"<label>","tone":"teal"}],
  "agent":{"ask":"<what the receiving agent should do>","receiverInstructions":"<optional directive>","core":[{"k":"topic","v":"..."},{"k":"ask","v":"..."},{"k":"for","v":"..."}]},
  "repoState":[{"repo":"...","branch":"...","pr_number":0,"base":"develop"}],
  "sections":[ { "id":"briefing", "label":"<short>", "title":"<statement>", "component":"<pick>", "...": "..." } ],
  "tags":["<author>","<date>"]
}
```

**Pick the component that fits each section's SHAPE** — do NOT default to prose:
- `claims` — a stat/outcome band → `items:[{v,l,tone}]`. Pull 2–3 key numbers/results into `highlights` (a top band) or a section.
- `steps` — a sequence / "here's what landed" → `items:[{title,body}]` (body is markdown); `after:"<wrap-up line>"` for a trailing summary.
- `tagcards` — decisions / disclosures / findings → `items:[{tag,tone,title,body,verdict}]` (tone: teal/brass/rose).
- `panels` — 2–3 options/comparison → `items:[{head,tone,body,points:[...]}]`.
- `compare` — before/after → `items:[{k:"// before",title,body,tone}]`.
- `ledger` — Q&A → `items:[{q,a}]`.
- `flow` — a staged loop → `items:[{tag,tone,title,body,conn}]`.
- `pullquote` — one sharp line → `{body}`.  `note` — a caveat/aside → `{body}`.
- `prose` — genuine narrative only → `{body}` (markdown). Use it sparingly.

**2. The markdown record — the memory/grep copy** (frontmatter + the material as plain markdown). This becomes the memory file + graph index and stays greppable; the JSON is what renders.

The JSON is a presentation map over the Markdown, not a second independently
authored summary. Every non-empty Markdown `##` section MUST have a stable
destination `id` in `sourceMap`, and that destination MUST retain every
meaningful source line. Rich components may rearrange the content but may not
drop prose, subheadings, expected output, or fenced commands.

If `$ARGUMENTS` narrows scope, constrain to that scope.

**Then RENDER AND CONFIRM before sending (the gate).** For generated content,
write both temp files and open the actual HTML with semantic coverage enabled:

```bash
node packages/egregore-artifacts/bin/cli.js composed "$COMPOSED_FILE" \
  --source "$BODY_FILE" --verify-fidelity
```

The browser artifact—not a text description of its components—is the approval
surface. If validation fails, repair the map/content and render again. Apply
requested edits and re-show the HTML. Skip only if the user said "just send
it".

## Step 3: Session Artifacts — automatic

Generated content may include session artifacts. Supplied content does not add
them unless the user asks. `handoff-run.sh` keeps supplied text free of inferred
session material by default.

The graph is the right tool here: indexed by date + author + tag, returns a structured list. A filesystem walk would have to read every file under `memory/knowledge/` and filter by frontmatter — slow and ugly. This is exactly the navigation-layer role the graph is built for.

Local mode: skipped silently (no graph). `artifacts` in the JSON will be an empty array.

## Step 4: Call the shared capture engine

For generated content, write the house-kit JSON to a temp file, then make one
bash call — the markdown record on stdin, the JSON via `--composed`:

```bash
cat > "${TMPDIR:-/tmp}/handoff-composed.json" <<'JSONEOF'
{ ...the Step 2 house-kit render spec... }
JSONEOF

bash bin/capture-run.sh \
  --mode addressed \
  --author <lowercase-handle> \
  --topic "<topic>" \
  --intent <action|feedback|fyi> \
  [--recipient <name>] \
  [--project <name>] \
  --content-mode generated \
  --composed "${TMPDIR:-/tmp}/handoff-composed.json" \
  <<'HANDOFFEOF'
---
capture_schema: egregore-capture/v1
capture_mode: addressed
kind: addressed
from: <lowercase-handle>
addressed_to: <recipient, if any>
date: YYYY-MM-DD
topic: <topic>
intent: <action | feedback | fyi>
content_mode: generated
claim: <one line — what this handoff is>
ask: <what the receiving agent should do>
receiver_instructions: <optional — a directive to the receiving agent>
---

<THE MATERIAL — plain markdown, the memory/grep record. Its own `## sections`,
its own prose. This is the record; the JSON is what renders.>
HANDOFFEOF
```

For supplied content, omit `--composed` and pass `--content-mode supplied`.
Pass `--include-session-artifacts` only when the user explicitly requested
those additions.

`--composed` is for generated content only. It renders the house-kit JSON while
the Markdown remains canonical. Supplied content renders directly from the
Markdown through native blocks. Both paths rerun the fidelity gate before
publication and fail closed when authored content is missing.

**Fallback body (only when nothing was prepared)** — replace the material with synthesized recipe sections:

```markdown
## Briefing

<2–4 sentences>

## Current State

<working / in progress / blocked>

## Next Steps

1. <clear action with entry point>
```

**`--author`**: lowercase handle only (see Step 0) — must match `from:`.

**`--project`**: derive from conversation context. Omit the flag if unclear.

**`intent` and `--intent`**: classify the recipient contract, not the prose
tone. Use `action` when the recipient should perform work, `feedback` when the
handoff asks for judgment/review/reply, and `fyi` when awareness is sufficient.
Pass the same value to `capture-run.sh --intent`. Never omit it: lifecycle
reconciliation deliberately refuses to auto-close `unclassified` handoffs.

**Frontmatter, not `**Key**:` lines.** The constrained core (`claim`/`ask`/`receiver_instructions`) drives the agent face and MUST be frontmatter — inline `**Key**:` lines leak into the reader body. Omit `receiver_instructions` if there's no specific directive. **Do NOT hand-write `## Repo State` or `## Session Artifacts`** — `handoff-run.sh` appends both, and the renderer routes Repo State into the agent face.

The addressed worker behind `capture-run.sh` handles, in one process:
1. File write to `memory/handoffs/YYYY-MM/DD-author-slug.md`
2. Append `## Repo State` section from `bin/repo-state.sh` if any repos are on non-base branches or have uncommitted changes
3. Prepend `memory/handoffs/index.md`
4. Index to Neo4j via `bin/index-handoff.sh` (connected mode only — Session
   node and BY/HANDED_TO/ABOUT edges); completion evidence is appended to the
   graph WAL and reconciled detached by the shared engine
5. Memory commit + pull-rebase-push to main (in parallel with 4)
6. Publish branded HTML artifact. Addressed handoffs may use the authenticated emissary API with recipient-private visibility; recipient-less team handoffs never become public emissaries and instead use `bin/publish-artifact.sh`. That publisher is **connected mode only by default** — with no org API key the upload would go to a public unauthenticated relay, which is opt-in (`bin/settings.sh relay on`). Skipped publishes are reported, never silent.
7. Create an exact notification proposal via `bin/notify.sh` without sending.
   Routing: `--recipient` set (including self) → direct message; no recipient
   → group. Local addressed handoffs report notification unavailable and never
   fall back to the group.
8. Emit one status line to stdout, write full result to `$TMPDIR/handoff-run-result.json`

## Step 5: Render the rich card

Call the deterministic renderer directly:

```bash
bash bin/render-card.sh --result "${TMPDIR:-/tmp}/handoff-run-result.json"
```

The renderer reads the briefing from the written handoff file's `## Briefing` section via `absFile` in the result JSON. `--briefing-file` and stdin remain supported as explicit overrides.

Output the renderer stdout VERBATIM — no reformatting, no re-drawing, no preamble, no sign-off sentence. The renderer owns degraded warnings, the fenced 72-column card, repo/artifact sections, status bits, and the link line below the fence.

## Step 5b: Separate notification consent

If `notifyStatus == "approval_required"`, follow
`.claude/context/notification-consent.md`. Read `notifyPlan` from the result and
use AskUserQuestion to show its exact organization, recipient/group, every
delivery/channel, and exact message. Offer Send / Edit / Cancel and stop for
the answer. Creating the handoff did not authorize the notification.

If the user selects Send, approve and dispatch that plan once. If they select
Edit, cancel the old plan, edit the message, create a new plan, and preview it
again. If they select Cancel, cancel it. If `notifyStatus == "unavailable"` or
`skipped`, do not ask and do not send.

### What NOT to output

- **No `&nbsp;`** or other HTML entities.
- **No raw JSON** — ever.
- **No `[N/5]` progress lines** — the Bash tool block is the progress indicator.
- **No "Team sees this on /activity."** footer boilerplate — status bits say everything.
- **No preamble** like "Handoff created successfully" — the box IS the acknowledgment.

## Step 6: Auto-save egregore-side — DETACHED, NON-BLOCKING

**Fire once, forget.** Handoffs happen at natural exit points; people walk away. Don't make them wait on git — but don't let their session work sit uncommitted either.

Immediately after rendering the card, fire `bin/handoff-save-egregore.sh` detached. It reparents to init, so it survives session exit:

```bash
( bash bin/handoff-save-egregore.sh "$AUTHOR" "$TOPIC" >/dev/null 2>&1 & ) >/dev/null 2>&1
```

Then, in the markdown below the box, add one line so the user knows it's happening:

```markdown
Saving core-repo changes in the background — non-coding changes will auto-merge to the configured base branch.
```

Omit that line if you already know there's nothing to save. Resolve the base with `_get_base_branch`, then check that `git status --porcelain` is empty AND `git rev-list --count "origin/$BASE_BRANCH..HEAD"` is 0. The helper does the same check itself — it's just cheaper to skip the line than to say "nothing to save".

**The helper does:**
1. Resolves the configured base from `egregore.json`, then early-exits only if the working tree is clean and no commits are ahead of `origin/{base}`.
2. If on the configured base (or another protected branch), creates `dev/{author}/handoff-YYYY-MM-DD` from `origin/{base}`.
3. Commits uncommitted work with message `Handoff: {topic}`.
4. Rebases onto `origin/{base}` (falls back to merge if rebase conflicts).
5. Pushes the working branch.
6. Creates (or reuses) a PR to the configured base.
7. **Non-coding diff → merge** — `.md` anywhere plus content under `artifacts/`, `docs/`, `.threads/` (policy: `bin/lib/noncode.sh`). Tries `gh pr merge --auto --merge`, falls back to an immediate `gh pr merge --merge` (repos without branch protection reject `--auto`). This is the common case for handoffs.
8. **Any code/config changes present → leave PR open for review.** No auto-merge for code. The user sees the PR next session.

Unresolvable conflicts or auth failures leave the branch as-is locally. The user will discover and resolve next session — no data loss, just a delayed merge.

Do NOT run `/save` inline here. `/save` is correct but slow (preflight, cypher checks, graph ops, managed-repo loop). For a handoff, the user is walking away — speed wins over completeness.

## Step 7: PR-number backfill — automatic

`handoff-run.sh` calls `bin/repo-state.sh --no-pr` to avoid the `gh pr list` round-trip per managed repo (~400–600ms each) on the hot path, then fires `bin/handoff-pr-backfill.sh` detached. The backfill rewrites `—` → `#N` for each row's open PR and re-commits the memory repo.

You don't do anything here. The orchestrator handles it. If the backfill fails (no `gh`, no open PR, network drop), the `—` stays — cosmetic only, branch names are the primary coordination mechanism.

## Step 8: Reflection prompt — CONNECTED MODE ONLY

After the card and auto-save, check if today's sessions produced no non-tutorial artifacts:

```bash
ARTIFACT_COUNT=$(bash bin/graph.sh query "
  MATCH (a:Artifact)-[:CONTRIBUTED_BY]->(p:Person {name: \$me})
  WHERE a.created >= datetime({year: $(date +%Y), month: $(date +%-m), day: $(date +%-d)})
    AND NOT 'tutorial-generated' IN coalesce(a.topics, [])
  RETURN count(a) AS artifactCount" 2>/dev/null | jq -r '.values[0][0] // 0' 2>/dev/null)
```

If `ARTIFACT_COUNT == 0`, show one line (NOT an AskUserQuestion — a soft nudge):

```
This session had insights worth capturing. Quick /reflect?
```

If artifacts exist, skip silently.

## Edge cases

| Scenario | Handling |
|---|---|
| `capture-run.sh` exits non-zero | Show last ~10 lines of its stderr plus "Run with `GRAPH_OP_VERBOSE=1` to debug." Do not retry automatically. |
| `graphStatus == "offline"` in connected mode | Warning line above box: `⚠ graph indexing failed — will sync on next /save`. Skip the reflection prompt (Step 8). |
| `memoryStatus == "failed"` | Warning line above box. Do not silently swallow. |
| `notifyStatus == "approval_required"` | Card says `notify approval pending`; Step 5b owns the separate exact preview. |
| `notifyStatus == "unavailable"` | Say no notification was sent. Never try another recipient or group. |
| Local mode + recipient specified | Direct notification is unavailable; no group fallback and no send. |
| Self-handoff (no recipient) | A group proposal may be created. It still requires the exact Step 5b approval. |
| Local mode + artifact publish | Skipped. Without an org API key the only fallback route is the public unauthenticated relay, which is opt-in (`bin/settings.sh relay on`). `publish-artifact.sh` exits 4 before rendering or uploading anything; `publishStatus` is `relay-off`, and the card shows a `not published` bit. The handoff still lands in `memory/handoffs/`; no notification is sent without Step 5b consent. |
| Addressed emissary publish | Uses the authenticated emissary API only when an explicit recipient exists. `addressed_to`, `visible_to`, and `extendable_by` all name that recipient; the link is not public. If the directed publish fails, normal connected/local fallback rules apply. |
| Recipient-less handoff | Never creates a public emissary as a side effect. Connected instances use their authenticated org-scoped artifact publisher; local instances stay on-machine unless the public relay was explicitly enabled. |
| Public relay explicitly enabled | `features.public_relay: true` → the OSS share endpoint is used (ephemeral 7-day TTL, unauthenticated). The handoff body is uploaded there. `published` bit as usual. |
| Empty session (nothing happened) | Ask "Nothing to hand off yet. Want to leave a note instead?" — don't create an empty file. |
| File already exists at path | The addressed worker appends `-N` to the slug to avoid collision. |
| No repos touched (all on base branch) | `bin/repo-state.sh` returns empty → `## Repo State` section omitted → REPOS omitted from TUI. |
| Managed repo dir missing | Skip silently in `bin/repo-state.sh` output. |
| Mid-session `/handoff` (not end-of-session) | Same flow. Briefing is whatever was in scope. Auto-save (Step 6) still fires. |
| Scoped briefing is very short | Fine — focused handoffs are better than muddled ones. |

## Status-line bits

| Bit | Present when |
|---|---|
| `saved` | Always — file is on disk. |
| `graphed` | `graphStatus == "ok"` — Session node created in Neo4j (connected mode only). |
| `pushed` | `memoryStatus == "ok"` — memory repo committed and pushed to main. |
| `notify approval pending` | `notifyStatus == "approval_required"` — exact destinations and message are resolved, but nothing was sent. |
| `published` | `artifactUrl` non-empty — branded HTML artifact published. |
| `not published` | `publishStatus == "relay-off"` — no org API key and the public relay is off, so nothing was uploaded. Expected default for a local/OSS instance. |

Missing bits are informative, not errors. `graphed` missing in local mode is normal. `pushed` missing under `--no-push` is normal. The handoff remains visible in `/activity` even when its optional external notification is cancelled or unavailable.
