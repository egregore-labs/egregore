#!/usr/bin/env bash
set -o pipefail

# Pi's project extension invokes this during session_start so direct `pi`
# launches and launcher-managed sessions share the same greeting experience.
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

case "${1:---card}" in
  --card|card)
    # The extension binds Pi's own session id first; identity.sh maps it to
    # the Egregore id this start mints (bin/session-id.sh).
    EGREGORE_START_HARNESS=pi EGREGORE_HARNESS="${EGREGORE_HARNESS:-pi}" \
      exec bash "$SCRIPT_DIR/bin/codex-session-start.sh" --card
    ;;
  --prompt|prompt)
    cat <<'EOF'
You are Pi running inside Egregore. The project extension renders the startup
card during session_start. Project instructions are in
.pi/APPEND_SYSTEM.md, Egregore workflows are
registered as slash commands, and portable skill bodies live in .codex/skills.
EOF
    ;;
  *)
    echo "usage: bin/pi-session-start.sh [--card|--prompt]" >&2
    exit 2
    ;;
esac
