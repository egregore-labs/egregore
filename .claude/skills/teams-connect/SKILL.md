---
name: teams-connect
description: "Set up Microsoft Teams as a notification channel for your Egregore — registers an Azure bot, uploads the app, and binds a channel. Use for /teams-connect, 'connect teams', or 'set up teams notifications'."
---

Set up Microsoft Teams as a notification channel for your Egregore.

Arguments: $ARGUMENTS (none expected)

## When to invoke

**Trigger phrases:**
- "set up teams", "connect teams", "teams-connect", "microsoft teams"
- "add teams notifications", "teams channel", "notify us on teams"

**Disambiguation:**
- "set up telegram" → `/telegram-connect`
- "send a message to teams" → NOT this — use the separate notification
  consent protocol in `.claude/context/notification-consent.md`

## What this does

Registers a bot in the org's own Microsoft tenant, installs it in their Teams,
and binds one channel to Egregore notifications. After this, everything that
plans a group notification may also resolve Teams as a receiving channel; all
resolved channels are shown before separate dispatch approval.

You (the agent) run all the Azure work via `az` after one browser login. The
human does exactly three things: one login, two portal clicks, one paste.

## OSS tier — visible, gated, honest

This skill ships to every Egregore, but Teams notifications run on the
Connected tier. **Before anything else**, detect the tier:

```bash
MODE=$(jq -r '.mode // empty' egregore.json 2>/dev/null)
API_URL=$(jq -r '.api_url // empty' egregore.json 2>/dev/null)
```

The tier predicate is exactly the canonical `_detect_mode` truth table
(`bin/lib/config.sh`): the instance is on the **local (OSS) tier** when
`MODE` is `local` **or** `API_URL` is empty. (A hand-set `mode: "connected"`
without an `api_url` is still local — never treat it as an unlock.)

On the local tier, deliver exactly this message, then the question — do not
paraphrase the message:

> You can expand your knowledge base with connections to Notion, Google Drive, Docs, Sheets, and many more. Upgrade to Connected Tier to accelerate.

AskUserQuestion:
- **Upgrade to Connected Tier** — tell them the one sanctioned path: run
  `egregore connect` in a terminal (the launcher walks the whole upgrade:
  registers your org with the platform, provisions the key, replays your
  graph). Teams notifications unlock once Connect is active.
- **Not now** — respect it and stop. Do not improvise config edits,
  api_url values, or partial flows.

Only continue past this section on a connected instance.

## Step 0: Prerequisites (check before touching anything)

Ask, or verify where possible. All three must be true:

1. **A Microsoft 365 tenant with Teams** (work tenant, not personal Teams).
2. **The person here is admin** of that tenant (Entra + Teams admin center).
3. **An Azure subscription** in that tenant — the bot resource is free (F0) but must live in a subscription.

`az` CLI must be installed: `which az` — if missing, `brew install azure-cli`
(macOS) or point at https://aka.ms/azure-cli for their OS.

## Step 1: Login (human, ~1 min)

Ask them to run in the prompt:
```
! az login
```
Then verify tenant + user:
```bash
az account show --query "{tenant:tenantId, user:user.name, state:state}" -o json
```

**Verify Teams is actually licensed** (the #1 silent dead-end — an Azure-only
tenant has no Teams and the Teams admin center errors with a cryptic
"can't find the tenant region for …" / PLS message):
```bash
az rest --method get --url "https://graph.microsoft.com/v1.0/subscribedSkus" \
  --query "value[].skuPartNumber" -o json
```
- `[]` or no Teams-bearing SKU → they need a license first. Guide: M365
  admin center → Marketplace → **Microsoft 365 Business Basic (Trial)**.
  **EEA trap:** every SKU marked "(no Teams)" literally excludes Teams
  (EU unbundling) — pick the plain variant, or add "Microsoft Teams EEA"
  separately. After purchase, assign the license (set `usageLocation` on the
  user first — `assignLicense` fails without it, and racing the two calls
  fails too: PATCH usageLocation, then assign in a separate call).
- Graph 403 `AADSTS530035` (security defaults) → `az logout && az login` fresh.

## Step 2: Azure infrastructure (agent, ~2 min)

Run these; capture every id/secret as you go:

```bash
# 1. App registration (single-tenant — deliberate; Microsoft is deprecating new multi-tenant bots)
az ad app create --display-name "Egregore Notifications" --sign-in-audience AzureADMyOrg \
  --query "{appId:appId}" -o json

# 2. Client secret (2 years)
az ad app credential reset --id <APP_ID> --display-name "teams-notify" --years 2 -o json

# 3. Service principal — az ad app create does NOT make one; skipping this
#    yields token 401 AADSTS7000229 later
az ad sp create --id <APP_ID>

# 4. Resource group + free Azure Bot + Teams channel
az group create -n egregore-bots -l <their-region, e.g. westeurope>
az bot create --resource-group egregore-bots --name egregore-notifications \
  --app-type SingleTenant --appid <APP_ID> --tenant-id <TENANT_ID> --sku F0
az bot msteams create --name egregore-notifications --resource-group egregore-bots
```

Save to the instance `.env` (gitignored — never commit):
```
TEAMS_APP_ID=…
TEAMS_APP_SECRET=…
TEAMS_TENANT_ID=…
```

Smoke the token before proceeding (catches AADSTS7000229 immediately):
```bash
curl -sS -X POST "https://login.microsoftonline.com/<TENANT_ID>/oauth2/v2.0/token" \
  -d grant_type=client_credentials -d "client_id=<APP_ID>" \
  -d "client_secret=<SECRET>" -d "scope=https://api.botframework.com/.default"
```

## Step 3: App package + catalog upload (human, 2 clicks)

Build and reveal the zip:
```bash
bash teams-app/build-package.sh <APP_ID> && open teams-app/build/
```
(If this instance doesn't carry `teams-app/`, fetch it from the framework repo.)

Guide them: **https://admin.teams.microsoft.com/policies/manage-apps** →
**Actions → Upload new app** → pick `egregore-teams-app.zip`.

Traps:
- Fresh tenants show "setting up your new app management experience… up to
  30 minutes" with the upload button greyed out. It's provisioning — wait, refresh.
- Re-uploading the same app id via "Upload new app" is rejected — updates go
  through the app's **detail page → Upload file to update**.

## Step 4: Add the bot to the team (human, 1 click)

In **Teams — the work account** (trap: the desktop app may silently be the
consumer client — "Build your community" UI, no org catalog; use
teams.microsoft.com if in doubt): **Apps → Built for your org → Egregore →
▾ → Add to a team** → pick the channel → **Set up a bot**.

Without this, sends fail `403 BotNotInConversationRoster`.

## Step 5: Channel binding (human pastes, agent decodes)

Ask for the channel link (channel → ⋯ → Get link to channel), then decode:
```bash
python3 -c "import sys,urllib.parse,re; m=re.search(r'(19%3a[^/?]+|19:[^/?]+)', sys.argv[1]); print(urllib.parse.unquote(m.group(1)))" "<PASTED_LINK>"
```
Result must look like `19:…@thread.tacv2`.

## Step 6: Persist

```bash
API_URL=$(jq -r '.api_url' egregore.json)
KEY=$(grep '^EGREGORE_API_KEY=' .env | cut -d= -f2-)
curl -sS -X POST "$API_URL/api/org/teams" \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"conversation_id":"<CONV_ID>","app_id":"<APP_ID>","app_secret":"<SECRET>","tenant_id":"<TENANT_ID>"}'
```
Expect `{"status":"connected", …}`. The per-org creds matter: a single-tenant
bot only works in its home tenant, so each org brings its own registration.

Non-default region: their bot's service URL may differ from the EMEA default —
pass `"service_url"` too (Azure portal → the bot → Channels → Teams shows it).

## Step 7: Verify with separate exact notification consent

Follow `.claude/context/notification-consent.md`. Connecting Teams is not
consent to send a test message. Prepare after configuration is final:
```bash
PLAN_JSON=$(bash bin/notify.sh plan group "Teams channel connected — this message reached you through Egregore.")
```

Show every resolved receiving channel—potentially both Telegram and Teams—and
the exact message in a dedicated Send / Edit / Cancel checkpoint. Only dispatch
after Send is selected for that preview. Card avatar may show a generic icon
for a few hours (Teams caches
app icons) — cosmetic, self-heals.

## Troubleshooting quick table

| Symptom | Cause → fix |
|---|---|
| "can't find the tenant region" (PLS) in Teams admin center | No M365/Teams license on the tenant → Step 1 licensing |
| Token 401 `AADSTS7000229` | Missing service principal → `az ad sp create --id <APP_ID>` |
| Send 403 `BotNotInConversationRoster` | Bot not added to the team → Step 4 |
| Send 404 | Wrong conversation id or wrong `service_url` region |
| "already an app with the same app ID" on upload | Use the app detail page → Upload file to update |
| No Apps rail / no org catalog in Teams | Consumer Teams client → work account at teams.microsoft.com |
| Upload button greyed out | Tenant still provisioning app management (≤30 min) |

## After

Emit telemetry (fire-and-forget):
```bash
bash bin/telemetry.sh emit "teams-connect" '{"command":"teams-connect"}' 2>/dev/null &
```
