# /me — View or set your display name

Show your profile or change how you're known across Egregore.

## When to invoke

- "who am I", "my profile", "my name", "what's my name"
- "call me oz", "I go by cem", "change my name to X"
- User runs `/me` or `/me <name>`

## Behavior

### No arguments → Show profile

Query the graph for the current user's Person node:

```bash
AUTHOR=$(jq -r '.github_username // empty' .egregore-state.json 2>/dev/null)
RESULT=$(bash bin/graph.sh query "MATCH (p:Person {github: \$gh}) RETURN p.name AS name, p.github AS github, p.fullName AS fullName, p.telegramUsername AS telegram" "{\"gh\":\"$AUTHOR\"}" 2>/dev/null)
```

Display:
```
  Name: {p.name}
  GitHub: {p.github}
  Full name: {p.fullName}
  Telegram: {p.telegramUsername or "not set"}
```

### With argument → Set display name

`$ARGUMENTS` is the new display name.

**Validate:**
1. Length: 1-30 characters
2. Characters: alphanumeric, spaces, hyphens only (`^[a-zA-Z0-9 -]+$`)
3. If validation fails, tell the user what's wrong and stop.

**Check uniqueness** — no other Person node should have the same name (case-insensitive):

```bash
AUTHOR=$(jq -r '.github_username // empty' .egregore-state.json 2>/dev/null)
RESULT=$(bash bin/graph.sh query "MATCH (p:Person) WHERE toLower(p.name) = toLower(\$name) AND p.github <> \$gh RETURN p.name AS name, p.github AS github LIMIT 1" "{\"name\":\"$ARGUMENTS\",\"gh\":\"$AUTHOR\"}" 2>/dev/null)
```

If a match is found: `"That name is already taken by {github}. Pick something else."`

**Update** (all three in parallel):

1. **State file:**
   ```bash
   jq --arg dn "$ARGUMENTS" '.display_name = $dn' .egregore-state.json > .egregore-state.json.tmp && mv .egregore-state.json.tmp .egregore-state.json
   ```

2. **Neo4j:**
   ```bash
   bash bin/graph.sh query "MATCH (p:Person {github: \$gh}) SET p.name = \$name RETURN p.name" "{\"gh\":\"$AUTHOR\",\"name\":\"$ARGUMENTS\"}"
   ```

3. **Supabase** (via API, non-blocking):
   ```bash
   API_URL=$(jq -r '.api_url // empty' egregore.json)
   API_KEY=$(grep '^EGREGORE_API_KEY=' .env | cut -d'=' -f2-)
   curl -sf "${API_URL}/api/user/ensure" \
     -H "Authorization: Bearer $API_KEY" \
     -H "Content-Type: application/json" \
     -d "{\"github_username\":\"$AUTHOR\",\"display_name\":\"$ARGUMENTS\"}" \
     --max-time 5 2>/dev/null || true
   ```

**Confirm:** `You're now known as **{name}**.`

## Rules

- All Neo4j via `bin/graph.sh`
- Never show raw JSON to the user
- Suppress bash output — only show formatted status
