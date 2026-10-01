#!/usr/bin/env bash
# Linked-worktree compatibility bridge for older Claude hook manifests.
# Current manifests call bin/observe-context.sh directly. Keep this historical
# filename as an adapter only; retrieval belongs to EgregoreRuntime.observe.

set -u

ROOT="${EGREGORE_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}}"
[ -f "$ROOT/bin/observe-context.sh" ] || exit 0

EGREGORE_ROOT="$ROOT" bash "$ROOT/bin/observe-context.sh" claude || true
