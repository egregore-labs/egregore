#!/usr/bin/env bash
set -o pipefail

# Prime Agent's project extension invokes this during session_start so direct
# `prime-agent` launches and launcher-managed sessions share the same greeting.
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

case "${1:---card}" in
  --card|card)
    # The extension binds Prime's own session id first; identity.sh maps it
    # to the Egregore id this start mints (bin/session-id.sh).
    EGREGORE_START_HARNESS=prime exec bash "$SCRIPT_DIR/bin/codex-session-start.sh" --card
    ;;
  --prompt|prompt)
    cat <<'EOF'
You are Prime Agent running inside Egregore. The project extension renders the
startup card during session_start. Project instructions are in
.prime/agent/APPEND_SYSTEM.md, Egregore workflows are registered as slash
commands, and portable skill bodies live in .codex/skills.
EOF
    ;;
  *)
    echo "usage: bin/prime-session-start.sh [--card|--prompt]" >&2
    exit 2
    ;;
esac
