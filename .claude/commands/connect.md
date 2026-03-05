Manage connectors — external services that bring context into Egregore.

Arguments: $ARGUMENTS (Optional: connector name + subcommand)

## Usage

- `/connect` — list available connectors
- `/connect google` — enable Google Workspace connector
- `/connect google status` — check connection status
- `/connect google revoke` — disconnect Google account

## When to invoke

**Trigger phrases:**
- "connect google", "enable google", "set up google workspace", "link google" → `/connect google`
- "disconnect google", "disable google", "revoke google", "unlink google" → `/connect google revoke`
- "connector status", "google status", "is google connected" → `/connect google status`
- "what connectors", "available connectors", "integrations" → `/connect`

**Disambiguation:**
- "connect to google" → `/connect google` (enablement flow)
- "search my google drive" → NOT /connect — user wants to use an already-connected service
- "ingest from google" → NOT /connect — route to `/ingest google` instead

## What to do

### Step 1: Parse arguments

```
$ARGUMENTS parsing:
  "" (empty)          → list available connectors
  "google"            → Google enablement flow (Step 2)
  "google status"     → status check (Step 3)
  "google revoke"     → revoke flow (Step 4)
```

### Step 2: Google enablement flow

1. **Check org config:**
   ```bash
   jq '.connectors.google.enabled // false' egregore.json
   ```
   If not enabled: "Google connector is not enabled for this org. An admin needs to add `connectors.google.enabled: true` to egregore.json."

2. **Check if already connected:**
   Read `.egregore-state.json` — if `google_auth_complete` is true, show status and ask if they want to reconnect.

3. **Run auth:**
   ```bash
   bash bin/connector-google.sh auth
   ```
   - **Local:** Opens browser for OAuth consent
   - **Hosted (CODER detected):** Shows API OAuth URL

4. **Select services:**
   Use AskUserQuestion — which services to enable:
   ```
   question: "Which Google services do you want to use?"
   options (from org config connectors.google.services):
     - Drive — files and folders
     - Gmail — email messages
     - Calendar — events and schedules
     - Docs — document content
     - Sheets — spreadsheet data
   multiSelect: true
   ```

5. **Update state:**
   ```bash
   bash bin/connector-google.sh enable <selected-services>
   ```

6. **Create context dirs:**
   ```bash
   bash bin/connector-google.sh sync
   ```

7. **Confirm:** "Connected as user@company.com. Services: drive, gmail, calendar."

8. **Telemetry:**
   ```bash
   bash bin/telemetry.sh emit "command" '{"command":"connect","connector":"google"}' 2>/dev/null &
   ```

### Step 3: Status check

```bash
bash bin/connector-google.sh status
```

Display the output to the user.

### Step 4: Revoke flow

```bash
bash bin/connector-google.sh auth revoke
```

Confirm: "Google access revoked. Run `/connect google` to reconnect."

### Step 5: List connectors (no arguments)

Read `egregore.json` → `connectors` section. List available connectors and their status:

```
Available connectors:
  Google Workspace  [connected / not connected / not enabled]
```

If no connectors configured: "No connectors are configured for this org. Add them to egregore.json."
