# bin/ — Egregore Framework Scripts

Shell scripts that power Egregore's session lifecycle, graph operations, and developer tooling. These run inside Claude Code sessions — they are hooks and helpers, not standalone CLI tools.

## Architecture

```
session-start.sh          ← SessionStart hook (orchestrator)
  ├── lib/identity.sh     ← User identity resolution
  ├── lib/git-sync.sh     ← Parallel git fetches, develop setup
  ├── lib/context.sh      ← 10 parallel context-gathering subshells
  └── lib/greeting.sh     ← ASCII art, status, session context

transcript-archive.sh     ← SessionEnd hook
pre-compact.sh            ← PreCompact hook

lib/
  ├── config.sh           ← Shared config helpers (_load_env_var, _config_val, _detect_mode)
  ├── hash.sh             ← Cross-platform md5 (_md5, _proj_hash)
  └── time.sh             ← Time helpers (_iso_to_epoch, _epoch_to_relative, _millis)
```

## Script Categories

### Session Lifecycle (hooks)
| Script | Hook | Purpose |
|--------|------|---------|
| `session-start.sh` | SessionStart | Identity, git sync, context gathering, greeting |
| `transcript-archive.sh` | SessionEnd | Archive transcript, drain WAL, launch Pulse |
| `pre-compact.sh` | PreCompact | Externalize knowledge to graph, re-inject state |
| `worktree-create.sh` | WorktreeCreate | Create branch + worktree + symlinks |
| `worktree-remove.sh` | WorktreeRemove | Clean up worktree + registry |

### Graph Operations
| Script | Purpose |
|--------|---------|
| `graph.sh` | Core query interface — API mode or offline |
| `graph-batch.sh` | Execute multiple Cypher queries in one HTTP call |
| `graph-op.sh` | Named operations (mark-read, set-topic, merge-person, etc.) |
| `graph-wal.sh` | Write-Ahead Log — resilient local buffer for graph writes |
| `graph-scribe.sh` | AI-powered artifact summarization |
| `graph-witness.sh` | Read-only quality evaluator (isolation, connectivity metrics) |
| `graph-maintenance.sh` | Scan for graph issues (stale handoffs, quest decay, etc.) |
| `sync-graph.sh` | Sync missing memory file nodes into Neo4j |
| `enrich-graph.sh` | Backfill topics, types, timestamps, resolve ghosts |

### Data & Analytics
| Script | Purpose |
|--------|---------|
| `activity-data.sh` | Fetch org activity dashboard data |
| `analytics-data.sh` | Fetch org-level analytics (10 metrics) |
| `dashboard-data.sh` | Fetch personal dashboard data |
| `pulse.sh` | Post-session synthesis via Sonnet |
| `pulse-report.sh` | Weekly Pulse report via Telegram |

### Infrastructure
| Script | Purpose |
|--------|---------|
| `telemetry.sh` | Privacy-respecting analytics (emit/flush/status/enable/disable) |
| `boundary.sh` | Path validation for environment isolation |
| `github-auth.sh` | GitHub device code flow authentication |
| `notify.sh` | Telegram notifications (send/group/test) |
| `worktree.sh` | Worktree lifecycle (setup/cleanup/health/list) |
| `ensure-shell-function.sh` | Install shell alias for quick access |
| `statusline.sh` | Branch + unsaved changes for status bar |

## Conventions

- **Local mode**: All scripts check `egregore.json → mode`. In `"local"` mode, graph/API/notification scripts return empty results gracefully.
- **Config loading**: Use `grep|cut` to extract `.env` values (never `source .env`). Use `jq` for `egregore.json`.
- **JSON construction**: Always use `jq -n --arg` — never manual string interpolation.
- **Error handling**: Background operations use `(...) &` with `|| true`. Hooks must not crash.
- **Telemetry**: Fire-and-forget via `bash bin/telemetry.sh emit "type" '{}' 2>/dev/null &`

## Validation

```bash
# Syntax check all scripts
for f in bin/*.sh; do bash -n "$f"; done

# Run pre-release OSS validator (52 checks)
bash bin/test-oss-release.sh

# ShellCheck (install: brew install shellcheck)
shellcheck bin/*.sh
```
