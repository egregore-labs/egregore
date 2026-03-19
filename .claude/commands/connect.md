Manage connectors — external services that bring context into Egregore.

Arguments: $ARGUMENTS (Optional: connector name + subcommand)

## Usage

- `/connect` — list available connectors
- `/connect google` — enable Google Workspace connector
- `/connect google status` — check connection status
- `/connect google revoke` — disconnect Google account
- `/connect granola` — enable Granola meeting integration (MCP)
- `/connect granola status` — check Granola MCP connection

## When to invoke

**Trigger phrases:**
- "connect google", "enable google", "set up google workspace", "link google" → `/connect google`
- "disconnect google", "disable google", "revoke google", "unlink google" → `/connect google revoke`
- "connect granola", "enable granola", "set up granola", "link granola", "granola meetings" → `/connect granola`
- "connector status", "google status", "is google connected" → `/connect google status`
- "granola status", "is granola connected" → `/connect granola status`
- "what connectors", "available connectors", "integrations" → `/connect`

**Disambiguation:**
- "connect to google" → `/connect google` (enablement flow)
- "search my google drive" → NOT /connect — user wants to use an already-connected service
- "ingest from google" → NOT /connect — route to `/ingest google` instead
- "connect granola" → `/connect granola` (MCP setup)
- "process a meeting" → NOT /connect — route to `/meeting` instead

## What to do

### Step 1: Parse arguments

```
$ARGUMENTS parsing:
  "" (empty)          → list available connectors
  "google"            → Google enablement flow (Step 2)
  "google status"     → status check (Step 3)
  "google revoke"     → revoke flow (Step 4)
  "granola"           → Granola enablement flow (Step 6)
  "granola status"    → Granola status check (Step 7)
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

Show all connectors and their status:

```
Available connectors:
  Google Workspace  [connected / not connected / not enabled]
  Granola           [connected / not connected]
```

For Google: check `egregore.json` → `connectors` section and `.egregore-state.json` → `google_auth_complete`.
For Granola: check `.claude/mcp.json` for the granola server config and use ToolSearch to verify MCP tools are loaded.

### Step 6: Granola enablement flow

1. **Check if MCP config exists:**
   Read `.claude/mcp.json` — check if `mcpServers.granola` is defined.

2. **If not configured**, add it:
   Read current `.claude/mcp.json`, add the Granola MCP server, write back:
   ```json
   {
     "mcpServers": {
       "granola": {
         "type": "url",
         "url": "https://mcp.granola.ai/mcp"
       }
     }
   }
   ```
   Preserve any existing MCP servers in the file.

3. **Check if MCP tools are available:**
   Use `ToolSearch` with query `"granola"` to check if tools are loaded.

4. **If tools are NOT loaded** (config just added or not yet authenticated):
   ```
   Granola MCP server configured. To complete setup:
   1. Restart Claude Code (the MCP server loads on startup)
   2. Run `/mcp` → select granola → Authenticate
   3. Complete the browser OAuth flow

   After authenticating, `/meeting` will have access to your Granola meetings.
   ```

5. **If tools ARE loaded** (already authenticated):
   Try calling `list_meetings` to verify the connection works.
   - **Success**: "Granola connected. Your meetings are accessible via `/meeting`."
   - **Auth error**: "Granola MCP is configured but authentication expired. Run `/mcp` → select granola → Authenticate."

6. **Update state:**
   ```bash
   jq '.connected_services.granola = true' .egregore-state.json > tmp.$$.json && mv tmp.$$.json .egregore-state.json
   ```

7. **Telemetry:**
   ```bash
   bash bin/telemetry.sh emit "command" '{"command":"connect","connector":"granola"}' 2>/dev/null &
   ```

### Step 7: Granola status check

1. Check `.claude/mcp.json` for granola config.
2. Use `ToolSearch` to check if MCP tools are loaded.
3. If tools are loaded, try `list_meetings` to verify auth.

Report:
```
Granola:
  MCP config: ✓ (https://mcp.granola.ai/mcp)
  MCP tools:  ✓ / ✗ (loaded / not loaded — restart Claude Code)
  Auth:       ✓ / ✗ (authenticated / expired — run /mcp → Authenticate)
```
