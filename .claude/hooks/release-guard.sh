#!/usr/bin/env bash
# release-guard.sh — non-blocking reminder when shippable surfaces are touched.
#
# Two trigger points (the script branches on event + tool):
#   - PostToolUse(Edit|Write): the instant a packages/** or api/** file is
#     edited, remind once per session per surface.
#   - PreToolUse(Bash): when a `git commit` is about to run with staged
#     packages/** or api/** changes, remind once per session per surface.
#
# Reminders only. NEVER blocks (always exit 0). The message reaches the model
# via PostToolUse/PreToolUse additionalContext; the model relays it to the
# user. This exists so non-technical teammates understand the consequence:
# bump the version / this auto-ships on merge to main.
#
# Heavy safety scanning (supply-chain, infra-boundary) lives in
# bin/release-safety.sh — this hook is just the gentle nudge.

# No set -e — a reminder must never crash a tool call.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
[ -d "$PROJECT_DIR" ] || exit 0

INPUT=$(cat 2>/dev/null) || exit 0
EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
SESSION=$(echo "$INPUT" | jq -r '.session_id // "nosession"' 2>/dev/null)
SESSION=${SESSION//[^a-zA-Z0-9_-]/_}

# --- emit additionalContext for the right event, then exit 0 ---
emit() {
  local event="$1" msg="$2"
  printf '%s' "$msg" | jq -Rsc --arg ev "$event" \
    '{ hookSpecificOutput: { hookEventName: $ev, additionalContext: . } }'
}

# --- dedup: once per (session, class, surface) ---
already_reminded() {
  local key="${SESSION}.${1}.${2}"
  key=${key//[^a-zA-Z0-9_.-]/_}
  local marker="${TMPDIR:-/tmp}/egregore-relguard.${key}"
  [ -f "$marker" ] && return 0
  : > "$marker" 2>/dev/null
  return 1
}

# --- map a path to a surface: "pkg:<name>" | "api" | "" (not shippable) ---
surface_for() {
  local p="$1"
  # strip absolute project prefix to a repo-relative path
  case "$p" in
    "$PROJECT_DIR"/*) p="${p#"$PROJECT_DIR"/}" ;;
    /*) # absolute but outside project (managed repo / memory) — ignore
        echo ""; return ;;
  esac
  case "$p" in
    packages/*/*)
      local pkg="${p#packages/}"; pkg="${pkg%%/*}"
      # ignore changelog/lock-only noise handled by caller; just classify here
      echo "pkg:$pkg" ;;
    api/*) echo "api" ;;
    *) echo "" ;;
  esac
}

# --- is a package's version already bumped vs origin/develop? ---
# echoes "bumped" | "unbumped" | "unknown"
version_state() {
  local pkg="$1"
  local f="packages/${pkg}/package.json"
  [ -f "$PROJECT_DIR/$f" ] || { echo "unknown"; return; }
  local cur base
  cur=$(jq -r '.version // empty' "$PROJECT_DIR/$f" 2>/dev/null)
  base=$(git -C "$PROJECT_DIR" show origin/develop:"$f" 2>/dev/null | jq -r '.version // empty' 2>/dev/null)
  [ -n "$cur" ] || { echo "unknown"; return; }
  [ -n "$base" ] || { echo "unknown"; return; }
  if [ "$cur" = "$base" ]; then echo "unbumped"; else echo "bumped"; fi
}

pkg_reminder() {
  local pkg="$1" name
  name=$(jq -r '.name // empty' "$PROJECT_DIR/packages/$pkg/package.json" 2>/dev/null)
  name=${name:-$pkg}
  local state; state=$(version_state "$pkg")
  if [ "$state" = "unbumped" ]; then
    cat <<EOF
release-guard: \`packages/$pkg/\` ($name) was changed but its version is NOT bumped (still matches origin/develop).

For this change to reach users, bump "version" in packages/$pkg/package.json IN THIS SAME change. On merge to main, the release pipeline auto-publishes any package whose version is new — an unbumped package ships nothing. Surface this to the user plainly (esp. for non-technical teammates): "bump the version or it won't publish; once merged to main it auto-deploys to npm."
EOF
  else
    cat <<EOF
release-guard: \`packages/$pkg/\` ($name) changed (version already bumped). Reminder: on merge to main this auto-publishes to npm via the release pipeline — no manual publish. Before /save, consider running bin/release-safety.sh.
EOF
  fi
}

api_reminder() {
  cat <<'EOF'
release-guard: `api/` changed. On merge to main this auto-deploys to Railway — no manual deploy step. Be deliberate: server-side change with real blast radius. Tell the user plainly that merging ships it, and verify before /save (bin/release-safety.sh).
EOF
}

case "$EVENT" in
  PostToolUse)
    case "$TOOL" in Edit|Write) ;; *) exit 0 ;; esac
    FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
    [ -n "$FILE" ] || exit 0
    SURF=$(surface_for "$FILE")
    [ -n "$SURF" ] || exit 0
    case "$SURF" in
      pkg:*)
        PKG="${SURF#pkg:}"
        already_reminded edit "$PKG" && exit 0
        emit PostToolUse "$(pkg_reminder "$PKG")" ;;
      api)
        already_reminded edit api && exit 0
        emit PostToolUse "$(api_reminder)" ;;
    esac
    exit 0 ;;

  PreToolUse)
    [ "$TOOL" = "Bash" ] || exit 0
    CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
    # Fast path: only care about commits.
    echo "$CMD" | grep -qE 'git[[:space:]]+commit' 2>/dev/null || exit 0
    # Which shippable surfaces are staged?
    STAGED=$(git -C "$PROJECT_DIR" diff --cached --name-only 2>/dev/null)
    [ -n "$STAGED" ] || exit 0
    OUT=""
    # api?
    if echo "$STAGED" | grep -qE '^api/' && ! already_reminded commit api; then
      OUT="$OUT$(api_reminder)"$'\n'
    fi
    # packages — one reminder per package
    while IFS= read -r pkg; do
      [ -n "$pkg" ] || continue
      already_reminded commit "$pkg" && continue
      OUT="$OUT$(pkg_reminder "$pkg")"$'\n'
    done < <(echo "$STAGED" | grep -E '^packages/[^/]+/' | sed -E 's#^packages/([^/]+)/.*#\1#' | sort -u)
    [ -n "$OUT" ] || exit 0
    emit PreToolUse "$OUT"
    exit 0 ;;

  *)
    exit 0 ;;
esac

exit 0
