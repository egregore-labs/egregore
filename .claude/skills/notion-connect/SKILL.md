Set up Notion as a content source for your Egregore. Guided, step by step — your workspace's own private connection, readable only by this Egregore.

Arguments: $ARGUMENTS (Optional: `status` or `revoke`)

## When to invoke

**Trigger phrases:**
- "connect notion", "set up notion", "link notion", "connect our notion", "enable notion" → run the setup flow
- "notion status", "is notion connected" → status
- "disconnect notion", "revoke notion", "unlink notion" → revoke

**Disambiguation:**
- "ingest from notion", "import our notion docs" → NOT this skill — route to `/ingest notion`
- "check notion for X" → NOT this skill — the connector is already usable: `bash bin/connector-notion.sh search "X"`

Design contract: `docs/specs/notion-connector.md`.

**CLI resolution (all commands below):** use `bash bin/connector-notion.sh`
when that file exists (framework checkout). On hosted Connect workspaces the
repo does not carry it — run `connector-notion.sh` from PATH instead (the
workspace image ships it at `/opt/egregore/bin`). If neither exists, Notion
isn't available in this installation — say so plainly and stop.

## OSS tier — visible, gated, honest

This skill ships to every Egregore, but the connector itself runs on the
Connected tier. **Before anything else**, detect the tier:

```bash
MODE=$(jq -r '.mode // empty' egregore.json 2>/dev/null)
API_URL=$(jq -r '.api_url // empty' egregore.json 2>/dev/null)
```

The tier predicate is exactly the canonical `_detect_mode` truth table
(`bin/lib/config.sh`): the instance is on the **local (OSS) tier** when
`MODE` is `local` **or** `API_URL` is empty. (A hand-set `mode: "connected"`
without an `api_url` is still local — never treat it as an unlock.) Deliver exactly this message, then the question — do not
paraphrase the message:

> You can expand your knowledge base with connections to Notion, Google Drive, Docs, Sheets, and many more. Upgrade to Connected Tier to accelerate.

AskUserQuestion:
- **Upgrade to Connected Tier** — tell them the one sanctioned path: run
  `egregore connect` in a terminal (the launcher walks the whole upgrade:
  registers your org with the platform, provisions the key, replays your
  graph). On hosted workspaces this skill unlocks on the next session; on
  self-hosted setups the connector itself is installed with our team during
  Connect onboarding — say that honestly rather than promising an instant
  unlock.
- **Not now** — respect it and stop. The skill is not usable on the local
  tier; do not improvise config edits, api_url values, or partial flows.

Only continue past this section on a connected instance.

## The one message that must always land

Open the flow with the privacy framing, in plain words, before any step:

> **This connection is private to your organization.** You create a key inside
> your own Notion workspace; it is stored only in this Egregore and never
> leaves your machines. **Egregore Labs has no access** — there is no Egregore
> app registered with Notion, no server that sees your key, nothing on their
> side that could read your content. You can revoke it in your Notion settings
> at any time.

Do not skip or paraphrase this into vagueness. It is the reason a
security-conscious org can say yes.

## Conduct rules

Agent-conducted — never a CLI interview. One step per turn. Verify each step
actually worked before offering the next. If the user is mid-flow from an
earlier attempt, run `bash bin/connector-notion.sh status` first and resume at
the right step instead of restarting.

## Setup flow

### Step 0 — Gates

```bash
jq '.connectors.notion.enabled // false' egregore.json
```
If false: "Notion isn't enabled for this org yet. An admin adds
`connectors.notion.enabled: true` to egregore.json." Stop.

Read `.egregore-state.json` — if `notion_auth_complete` is true, show
`bash bin/connector-notion.sh status` and ask whether they want to reconnect
or are here to revoke. Skip the rest when already healthy.

### Step 1 — Framing + owner check

Deliver the privacy message above. Then confirm the user is (or can reach) a
**Notion workspace owner** — only an owner can create the connection. If they
are not, help them draft the one-line ask to their admin and stop until the
owner is present.

### Step 2 — Create the connection (their workspace, their key)

Open the portal for them:

```bash
open "https://app.notion.com/developers"
```

Narrate, one screen at a time, and wait for their confirmation before moving
on. The portal's create dialog and the capabilities screen are **separate**
steps — do not conflate them.

**Create dialog:**

1. Click **+ New connection**
2. Name it `<org> Egregore`
3. Authentication method: **Access token** — workspace-scoped static token,
   which is what an org connector wants. (Not OAuth: that one is user-scoped
   and for marketplace apps.)
4. **Installable in**: confirm it shows their workspace
5. Click **Create connection**

**Capabilities** — Notion does *not* take them there automatically. Guide
them: portal sidebar → **Connections** → click the new `<org> Egregore`
connection → **Configuration** tab. The defaults are broader than needed
(update/insert content and user info can be pre-enabled), so this step is
about turning things off:

6. Recommended: keep **Read content** + **Read comments**; disable
   **Update content**, **Insert content**, and set user information to
   **No user information**.
   One genuine choice to offer, not bury: if they want Egregore to write to
   Notion later (create or update pages), they can leave Update/Insert
   enabled — note their choice and move on. Read-only stays the recommended
   default.
7. Save, then reveal and copy the **Access token** — it starts with `ntn_`.

### Step 3 — Store the key (never through chat)

The user just copied the key, so it is on their clipboard. In-session (`!`
commands have no interactive terminal), the clipboard pipe is the way — the
key appears nowhere, not in the command line and not in the log:

```
! pbpaste | bash bin/connector-notion.sh auth set
```

(Linux: `xclip -o |` or `wl-paste |` instead of `pbpaste |`.) In a real
terminal, plain `bash bin/connector-notion.sh auth set` gives a hidden
prompt instead. Either way the CLI validates the key against the API and
writes gitignored `.env` only on success. **If they paste the key into the
chat itself**, accept it gracefully but tell them to rotate it in the
developer portal afterwards — chat transcripts are captured; this flow exists
so the key never is.

Verify:

```bash
bash bin/connector-notion.sh auth status
```

Report the workspace name back (or, with minimal capabilities, the
token-valid-but-name-unavailable note — that is success, say so).

### Step 4 — Choose what it can see

On the connection's page in the portal: the **Content access** tab →
**+ Add pages & databases**. Granting a top-level page or teamspace includes
everything under it. The same tab lists current access and revokes it —
their side, unilateral, any time. (Also reachable from inside Notion via
Settings → Connections → the connection.)

Prove it:

```bash
bash bin/connector-notion.sh list --max 5
```

Titles come back → connected. Empty → nothing shared yet; return to the
settings screen with them.

### Step 5 — Land it

Update state (the CLI already wrote `notion_connector` / `notion_auth_complete` /
`notion_workspace`). Telemetry, fire-and-forget:

```bash
bash bin/telemetry.sh emit "command" '{"command":"notion-connect"}' 2>/dev/null &
```

Close with the next move, not a manual: "Connected. Say **/ingest notion**
and I'll shortlist the five docs most worth bringing into shared memory —
you pick, I import."

## Status

```bash
bash bin/connector-notion.sh status
```

Show org gate, key validity, workspace, last sync — formatted, no raw JSON.

## Revoke

```bash
bash bin/connector-notion.sh auth revoke
```

Confirm: "Key removed from this Egregore. To kill the key itself, also delete
the connection in Notion → Settings → Connections."
