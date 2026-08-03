#!/usr/bin/env bash
# boundary-check.sh — PreToolUse hook for environment isolation
# Receives tool input JSON on stdin from Claude Code.
# Exit 0 = allow, exit 2 = block (reason on stderr).
# Must be fast (<50ms) — no network calls, just path checks.
#
# Two-tier model (decided 2026-07-08, harvest-2026-07-08-boundary-hook-refinement):
#   HARD tier — paths of other Egregore instances (denied_paths): denied for
#               every tool, always. No consent path exists.
#   SOFT tier — everything else outside the boundary: consent-gated for every
#               tool. Grants live in .egregore-boundary-consent (session-scoped,
#               cleared by session-start) or in config read roots.
# Posture (strict|standard|open), lock, and read roots are merged at session
# start from egregore.json .boundary + .egregore-boundary.local.json into the
# cached boundary JSON. Sessions running with permission_mode=bypassPermissions
# skip the soft tier (never the hard tier) unless the org boundary is locked.

# No set -e — hook must never accidentally block by crashing
# If anything fails unexpectedly, fall through to exit 0 (allow)

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"

# --- Guard: if project dir no longer exists (worktree deleted), allow gracefully ---
if [ ! -d "$PROJECT_DIR" ]; then
  exit 0
fi

# --- Load boundary file (cached at session start) ---
HASH=$(echo -n "$PROJECT_DIR" | md5 2>/dev/null || echo -n "$PROJECT_DIR" | md5sum 2>/dev/null | cut -d' ' -f1)
BOUNDARY_FILE="/tmp/egregore-boundary-${HASH}.json"

if [ ! -f "$BOUNDARY_FILE" ]; then
  # No boundary computed yet (session-start hasn't run) — allow everything
  exit 0
fi

# Read boundary once. Empty fields carry a "-" sentinel: tab counts as IFS
# whitespace, so a genuinely empty @tsv field would collapse and shift every
# following field left.
BOUNDARY_JSON=$(cat "$BOUNDARY_FILE" 2>/dev/null) || exit 0
IFS=$'\t' read -r B_PROJECT_DIR B_MEMORY_DIR POSTURE LOCKED HAS_READ_ROOTS < <(
  echo "$BOUNDARY_JSON" | jq -r \
    '[(.project_dir // "" | if . == "" then "-" else . end), (.memory_dir // "" | if . == "" then "-" else . end), (.posture // "standard"), ((.locked // false) | tostring), (has("read_roots") | tostring)] | @tsv' 2>/dev/null
) || true
[ "$B_PROJECT_DIR" = "-" ] && B_PROJECT_DIR=""
[ "$B_MEMORY_DIR" = "-" ] && B_MEMORY_DIR=""
case "$POSTURE" in strict|standard|open) ;; *) POSTURE="standard" ;; esac
[ "$LOCKED" = "true" ] || LOCKED="false"

# Read roots: from boundary JSON when present; legacy boundary files (no key)
# get the inbox defaults, matching the default posture.
if [ "$HAS_READ_ROOTS" = "true" ]; then
  READ_ROOTS=$(echo "$BOUNDARY_JSON" | jq -r '.read_roots[]?' 2>/dev/null) || true
elif [ "$POSTURE" != "strict" ]; then
  READ_ROOTS="$HOME/Downloads
$HOME/Desktop"
else
  READ_ROOTS=""
fi

DENIED_PATHS=$(echo "$BOUNDARY_JSON" | jq -r '.denied_paths[]?' 2>/dev/null) || true

CONSENT_FILE="$PROJECT_DIR/.egregore-boundary-consent"

# --- Read tool input from stdin ---
INPUT=$(cat)
IFS=$'\t' read -r TOOL_NAME PERM_MODE < <(
  echo "$INPUT" | jq -r '[(.tool_name // "" | if . == "" then "-" else . end), (.permission_mode // "")] | @tsv' 2>/dev/null
) || true
[ "$TOOL_NAME" = "-" ] && TOOL_NAME=""

if [ -z "$TOOL_NAME" ]; then
  exit 0
fi

# Yolo inheritance: a session the user runs in bypassPermissions has already
# declared maximal trust — Egregore doesn't re-ask (soft tier off). The hard
# tier stays on. An org lock disables this relaxation.
RELAXED="false"
if [ "$LOCKED" != "true" ] && [ "$PERM_MODE" = "bypassPermissions" ]; then
  RELAXED="true"
fi

# --- Helper: resolve path ---
resolve_path() {
  local path="$1"
  path="${path/#\~/$HOME}"
  path="${path/#\$HOME/$HOME}"
  if [[ "$path" != /* ]]; then
    path="$PROJECT_DIR/$path"
  fi
  realpath "$path" 2>/dev/null || echo "$path"
}

# --- Helper: HARD tier — another instance's path? ---
is_denied() {
  local resolved="$1" denied
  for denied in $DENIED_PATHS; do
    if [[ "$resolved" == "$denied" || "$resolved" == "$denied/"* ]]; then
      return 0
    fi
  done
  return 1
}

# --- Helper: core boundary (no consent needed, all tiers) ---
in_core_boundary() {
  local resolved="$1"

  # Always-allowed system paths
  case "$resolved" in
    /tmp/*|/tmp|/private/*|/private) return 0 ;;
    "$HOME/.claude"/*|"$HOME/.claude") return 0 ;;
    /usr/*|/etc/*|/var/*|/bin/*|/sbin/*|/opt/*) return 0 ;;
    /dev/*|/dev|/proc/*|/sys/*) return 0 ;;
    /System/*|/Applications/*|/Library/*) return 0 ;;
  esac

  # Allow reading instance registry (needed for multi-instance features)
  if [[ "$resolved" == "$HOME/.egregore"/* ]]; then
    return 0
  fi

  # Project directory
  if [ -n "${B_PROJECT_DIR:-}" ]; then
    if [[ "$resolved" == "$B_PROJECT_DIR" || "$resolved" == "$B_PROJECT_DIR/"* ]]; then
      return 0
    fi
  fi

  # Memory directory
  if [ -n "${B_MEMORY_DIR:-}" ]; then
    if [[ "$resolved" == "$B_MEMORY_DIR" || "$resolved" == "$B_MEMORY_DIR/"* ]]; then
      return 0
    fi
  fi

  # Managed repos
  local repo_paths repo_path
  repo_paths=$(echo "$BOUNDARY_JSON" | jq -r '.managed_repos[]?' 2>/dev/null) || true
  for repo_path in $repo_paths; do
    if [[ "$resolved" == "$repo_path" || "$resolved" == "$repo_path/"* ]]; then
      return 0
    fi
  done

  # Parent directory (for sibling repo operations). Denied paths are checked
  # before this helper is ever consulted, so no denied check needed here.
  local parent_dir
  parent_dir="$(dirname "${B_PROJECT_DIR:-$PROJECT_DIR}")"
  if [[ "$resolved" == "$parent_dir" || "$resolved" == "$parent_dir/"* ]]; then
    return 0
  fi

  return 1
}

# --- Helper: SOFT tier grants ---
in_read_roots() {
  local resolved="$1" root
  for root in $READ_ROOTS; do
    if [[ "$resolved" == "$root" || "$resolved" == "$root/"* ]]; then
      return 0
    fi
  done
  return 1
}

is_consented() {
  local resolved="$1" line
  # A locked org boundary has no consent path — stale grant files are void.
  [ "$LOCKED" = "true" ] && return 1
  [ -f "$CONSENT_FILE" ] || return 1
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    line="${line/#\~/$HOME}"
    if [[ "$resolved" == "$line" || "$resolved" == "$line/"* ]]; then
      return 0
    fi
  done < "$CONSENT_FILE"
  return 1
}

# --- Block messages ---
block_hard() {
  local resolved="$1"
  echo "Environment isolation: $resolved belongs to another Egregore instance. Access is denied for every tool and cannot be consented — do not retry and do not attempt via other tools. If the user needs something from it, they must fetch it themselves in that instance." >&2
  exit 2
}

block_soft() {
  local resolved="$1" action="$2" dir
  dir=$(dirname "$resolved")
  if [ "$LOCKED" = "true" ]; then
    echo "Environment isolation: $resolved is outside this instance's boundary and the org boundary is locked (egregore.json boundary.locked) — no consent path exists. Do not retry. Use AskUserQuestion with options: 'Paste contents inline' / 'Move the file into the repo and point me at the new path' / 'Cancel'." >&2
  else
    echo "Boundary consent needed: $resolved is outside this instance's $action surface (posture: $POSTURE). Do not retry yet and do not route around via other tools. Ask via AskUserQuestion with exactly these options: 'Allow $dir for this session' (on approval: append $dir as one line to $PROJECT_DIR/.egregore-boundary-consent, then retry) / 'Always allow on this instance' (on approval: add \"$dir\" to the read[] array in $PROJECT_DIR/.egregore-boundary.local.json, then retry) / 'Paste contents inline' / 'Cancel'. Never write a consent grant without the user's explicit approval in this exchange." >&2
  fi
  exit 2
}

# --- Check based on tool type ---
case "$TOOL_NAME" in
  Read|Glob|Grep)
    if [ "$TOOL_NAME" = "Read" ]; then
      FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null) || true
    else
      FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.path // empty' 2>/dev/null) || true
    fi
    if [ -z "${FILE_PATH:-}" ]; then
      exit 0  # No path = CWD = project dir, allowed
    fi

    RESOLVED=$(resolve_path "$FILE_PATH")
    is_denied "$RESOLVED" && block_hard "$RESOLVED"
    in_core_boundary "$RESOLVED" && exit 0
    [ "$POSTURE" = "open" ] && exit 0
    [ "$RELAXED" = "true" ] && exit 0
    in_read_roots "$RESOLVED" && exit 0
    is_consented "$RESOLVED" && exit 0
    block_soft "$RESOLVED" "read"
    ;;

  Edit|Write)
    FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null) || true
    if [ -z "${FILE_PATH:-}" ]; then
      exit 0
    fi

    RESOLVED=$(resolve_path "$FILE_PATH")
    is_denied "$RESOLVED" && block_hard "$RESOLVED"
    in_core_boundary "$RESOLVED" && exit 0
    # Read roots and posture=open grant reads only — writes always need
    # consent (or a bypassPermissions session, unless locked).
    [ "$RELAXED" = "true" ] && exit 0
    is_consented "$RESOLVED" && exit 0
    block_soft "$RESOLVED" "write"
    ;;

  Bash)
    COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || true
    if [ -z "${COMMAND:-}" ]; then
      exit 0
    fi

    # HARD tier: denied instance paths anywhere in the command
    for denied in ${DENIED_PATHS:-}; do
      if echo "$COMMAND" | grep -qF "$denied" 2>/dev/null; then
        block_hard "$denied"
      fi
    done

    # SOFT tier: best-effort. Only user-home-area path literals are checked —
    # system paths are core-allowed and relative paths stay inside the project.
    # A missed path degrades to "no prompt", never to a hard-tier breach.
    [ "$POSTURE" = "open" ] && exit 0
    [ "$RELAXED" = "true" ] && exit 0

    CANDIDATES=$(echo "$COMMAND" | grep -oE '(~|\$HOME|/Users/[A-Za-z0-9._-]+)/[A-Za-z0-9._/-]+' 2>/dev/null | sort -u | head -20) || true
    for c in $CANDIDATES; do
      RESOLVED=$(resolve_path "$c")
      is_denied "$RESOLVED" && block_hard "$RESOLVED"
      in_core_boundary "$RESOLVED" && continue
      in_read_roots "$RESOLVED" && continue
      is_consented "$RESOLVED" && continue
      block_soft "$RESOLVED" "shell"
    done
    ;;

  *)
    # Other tools (WebFetch, etc.) — allow
    exit 0
    ;;
esac

# Default: allow
exit 0
