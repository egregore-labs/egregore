#!/usr/bin/env bash
# Session-record admission is silent and detached for hooks. Python uses only
# the standard library. Summarizer flags (all checked against claude --help):
# Private trails, durable holds, stamps and locks live in $HOME/.egregore/trails.
# --tools "" --strict-mcp-config --mcp-config '{"mcpServers":{}}'
# --setting-sources "" --model MODEL --output-format text -p PROMPT
# Built-in tools, MCP servers, project settings, hooks and plugins are disabled,
# so the call is a single turn without a separate turn-limit flag.
# A CLI missing any isolation flag (including the empty --tools allowlist)
# is never invoked for a build; the record is deterministic instead.
# Checkpoints only write the record file in the memory working tree. Session
# end commits and pushes it with this person's earlier uncommitted records.
# --mode sweep always refreshes local counts in a detached worker. Publication
# requires an answered offer and enabled recording; only publication is
# debounced for six hours unless --force is supplied.
# Publications and hold markers use the same canonical memory lock; holds wait
# for an active publication, then redact going forward without rewriting history.
# The one thing a hook prints: at a checkpoint, the session's cost line, once
# per mark ($200 priced, or ten million Codex input tokens) at the next stop.
# Descriptor 3 carries the hook's stdout past the silenced streams for it.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)" || exit 0
command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0
[ -n "${HOME:-}" ] || exit 0
exec python3 "$SCRIPT_DIR/bin/lib/session_record.py" record --root "$SCRIPT_DIR" --notice-fd 3 "$@" 3>&1 >/dev/null 2>&1
