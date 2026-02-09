Update local Egregore environment — pull latest and sync shared MCP config.

## What to do

1. **Run `/pull`** (smart sync all repos)
2. **Merge shared MCPs** from `mcp.shared.json` into local `.mcp.json`
3. Report what changed
4. Remind to restart if MCPs changed

## MCP config merging

```bash
# Read mcp.shared.json (repo) and .mcp.json (local)
# For each server in shared:
#   - If not in local: add it (new)
#   - If in local: keep local version (unchanged)
# Personal MCPs in local but not in shared: keep them
```

## Files

- `mcp.shared.json` — shared MCPs (committed to repo)
- `.mcp.json` — local config (gitignored, personal + shared merged)

## Example

```
> /update

Pulling...
  [memory]    ✓ 3 new commits
  [egregore]  ✓ 1 new commit
  [tristero]  ✓ current
  [lace]      ✓ current

Updating MCP config...
  + neo4j (new)
  = telegram (unchanged)
  · supabase (yours, kept)
  · tristero (yours, kept)

⚠ MCP config changed — restart Claude Code to load neo4j
```

## If no MCP changes

```
Updating MCP config...
  = neo4j (unchanged)
  = telegram (unchanged)
  · supabase (yours, kept)

✓ No restart needed
```

## Next

Restart Claude Code if MCPs changed, then `/activity` to see what's new.
