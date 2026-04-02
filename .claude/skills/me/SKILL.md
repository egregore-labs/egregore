# /me — View or set your display name

Show your profile or change how you're known across Egregore.

## When to invoke

- "who am I", "my profile", "my name", "what's my name"
- "call me oz", "I go by cem", "change my name to X"
- User runs `/me` or `/me <name>`

## Behavior

### No arguments → Show profile

```bash
AUTHOR=$(jq -r '.github_username // empty' .egregore-state.json 2>/dev/null)
DISPLAY_NAME=$(jq -r '.display_name // empty' .egregore-state.json 2>/dev/null)
```

**Connected mode:** Query the graph for the full Person node:
```bash
RESULT=$(bash bin/graph.sh query "MATCH (p:Person {github: \$gh}) RETURN p.name AS name, p.github AS github, p.fullName AS fullName, p.telegramUsername AS telegram" "{\"gh\":\"$AUTHOR\"}" 2>/dev/null)
```

**Local mode:** Read from people file:
```bash
PEOPLE_FILE="memory/people/${AUTHOR}.md"
FILE_NAME=$(head -1 "$PEOPLE_FILE" 2>/dev/null | sed 's/^# //')
ROLE=$(grep '^Role:' "$PEOPLE_FILE" 2>/dev/null | cut -d: -f2- | xargs)
```

Display:
```
  Name: {display_name or file header name}
  GitHub: {github_username}
  Role: {role or "not set"}
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

**Update** (all five in parallel):

1. **State file:**
   ```bash
   jq --arg dn "$ARGUMENTS" '.display_name = $dn' .egregore-state.json > .egregore-state.json.tmp && mv .egregore-state.json.tmp .egregore-state.json
   ```

2. **People file** (canonical in local mode):
   ```bash
   PEOPLE_FILE="memory/people/${AUTHOR}.md"
   if [ -f "$PEOPLE_FILE" ]; then
     sed -i '' "1s/^# .*/# $ARGUMENTS/" "$PEOPLE_FILE" 2>/dev/null \
       || sed -i "1s/^# .*/# $ARGUMENTS/" "$PEOPLE_FILE"
   fi
   ```

4. **Neo4j — update name + store previous name (connected mode only):**
   ```bash
   bash bin/graph.sh query "MATCH (p:Person {github: \$gh}) WITH p, p.name AS oldName SET p.name = \$name, p.previousNames = CASE WHEN oldName IS NOT NULL AND oldName <> \$name THEN coalesce(p.previousNames, []) + oldName ELSE coalesce(p.previousNames, []) END RETURN p.name" "{\"gh\":\"$AUTHOR\",\"name\":\"$ARGUMENTS\"}"
   ```

5. **Neo4j — merge orphaned duplicate (connected mode only)** (absorb any Person node with the new name that has no github):
   ```bash
   bash bin/graph.sh query "MATCH (real:Person {github: \$gh}), (orphan:Person) WHERE toLower(orphan.name) = toLower(\$name) AND (orphan.github IS NULL OR orphan.github = '') AND orphan <> real WITH real, orphan OPTIONAL MATCH (s1)-[:BY]->(orphan) FOREACH (_ IN CASE WHEN s1 IS NOT NULL THEN [1] ELSE [] END | MERGE (s1)-[:BY]->(real)) WITH real, orphan OPTIONAL MATCH (s2)-[:HANDED_TO]->(orphan) FOREACH (_ IN CASE WHEN s2 IS NOT NULL THEN [1] ELSE [] END | MERGE (s2)-[:HANDED_TO]->(real)) WITH real, orphan OPTIONAL MATCH (m)-[:INVOLVES]->(orphan) FOREACH (_ IN CASE WHEN m IS NOT NULL THEN [1] ELSE [] END | MERGE (m)-[:INVOLVES]->(real)) WITH real, orphan OPTIONAL MATCH (a)-[:CONTRIBUTED_BY]->(orphan) FOREACH (_ IN CASE WHEN a IS NOT NULL THEN [1] ELSE [] END | MERGE (a)-[:CONTRIBUTED_BY]->(real)) WITH real, orphan OPTIONAL MATCH (i)-[:CONDUCTED_BY]->(orphan) FOREACH (_ IN CASE WHEN i IS NOT NULL THEN [1] ELSE [] END | MERGE (i)-[:CONDUCTED_BY]->(real)) WITH real, orphan DETACH DELETE orphan RETURN 'merged' AS status" "{\"gh\":\"$AUTHOR\",\"name\":\"$ARGUMENTS\"}" 2>/dev/null || true
   ```
   This is best-effort — transfers known relationship types from the orphan to the real node, then deletes the orphan.

6. **Supabase (connected mode only)** (via API, non-blocking):
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
