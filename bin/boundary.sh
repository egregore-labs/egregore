#!/usr/bin/env bash
# boundary.sh — Path validation and consent utility for environment isolation
#
#   boundary.sh check <path>              — exits 0 if path is within boundary
#   boundary.sh validate-repos            — validates egregore.json repos[]
#   boundary.sh grant [opts] <dir>        — record a consent grant for <dir>
#   boundary.sh revoke [opts] <dir>       — remove a grant for <dir>
#   boundary.sh grants                    — show the grants currently in effect
#   boundary.sh refresh                   — recompute the cached boundary policy
#
# `grant` is the single supported way to widen the soft tier. It exists because
# the PreToolUse hook's remedy necessarily names the blocked path, so any
# ad-hoc shell command that wrote the grant tripped the very check it was
# meant to clear. The hook exempts exactly this command, and this command
# refuses to grant a hard-tier (other-instance) path or to write anything at
# all while the org boundary is locked — so the exemption cannot become a hole.
set -euo pipefail

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  echo "Usage: boundary.sh <command> [args...]"
  echo ""
  echo "Path validation and consent utility for environment isolation."
  echo "Ensures sessions stay within their allowed boundaries."
  echo ""
  echo "Commands:"
  echo "  check <path>            Exit 0 if path is within boundary, 1 if not"
  echo "  validate-repos          Check egregore.json repos[] for path traversal"
  echo "  grant [opts] <dir>      Allow <dir> outside the boundary"
  echo "  revoke [opts] <dir>     Remove a grant for <dir>"
  echo "  grants                  Show grants currently in effect"
  echo "  refresh                 Recompute the cached boundary policy now"
  echo ""
  echo "grant/revoke options:"
  echo "  --always   Persist in .egregore-boundary.local.json (default: this session only)"
  echo "  --write    Grant write access too (default: read only)"
  echo ""
  echo "Grants require the user's explicit approval — never run this to silence a block."
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# --- Load boundary file ---
# Boundary file is written by session-start.sh at /tmp/egregore-boundary-{hash}.json
# Hash is md5 of the project directory path for uniqueness
load_boundary() {
  local hash
  hash=$(echo -n "$SCRIPT_DIR" | md5 2>/dev/null || echo -n "$SCRIPT_DIR" | md5sum 2>/dev/null | cut -d' ' -f1)
  BOUNDARY_FILE="/tmp/egregore-boundary-${hash}.json"

  if [ ! -f "$BOUNDARY_FILE" ]; then
    # No boundary file — fall back to project dir only
    PROJECT_DIR="$SCRIPT_DIR"
    MEMORY_DIR=""
    MANAGED_REPOS=""
    DENIED_PATHS=""
    return
  fi

  PROJECT_DIR=$(jq -r '.project_dir // empty' "$BOUNDARY_FILE" 2>/dev/null)
  MEMORY_DIR=$(jq -r '.memory_dir // empty' "$BOUNDARY_FILE" 2>/dev/null)
  MANAGED_REPOS=$(jq -r '.managed_repos[]? // empty' "$BOUNDARY_FILE" 2>/dev/null)
  DENIED_PATHS=$(jq -r '.denied_paths[]? // empty' "$BOUNDARY_FILE" 2>/dev/null)
}

# --- Resolve path to absolute ---
resolve_path() {
  local path="$1"
  # Expand ~ to $HOME
  path="${path/#\~/$HOME}"
  # Resolve to absolute
  if [[ "$path" != /* ]]; then
    path="$SCRIPT_DIR/$path"
  fi
  # Resolve symlinks and ../ components
  realpath "$path" 2>/dev/null || echo "$path"
}

# --- Check if path is within an allowed directory ---
path_starts_with() {
  local path="$1"
  local prefix="$2"
  [[ "$path" == "$prefix" || "$path" == "$prefix/"* ]]
}

# --- MODE: check <path> ---
check_path() {
  local target="$1"
  local resolved
  resolved=$(resolve_path "$target")

  load_boundary

  # Always-allowed system paths
  if path_starts_with "$resolved" "/tmp"; then return 0; fi
  if path_starts_with "$resolved" "$HOME/.claude"; then return 0; fi
  if path_starts_with "$resolved" "/usr"; then return 0; fi
  if path_starts_with "$resolved" "/etc"; then return 0; fi
  if path_starts_with "$resolved" "/var"; then return 0; fi
  if path_starts_with "$resolved" "/bin"; then return 0; fi
  if path_starts_with "$resolved" "/sbin"; then return 0; fi
  if path_starts_with "$resolved" "/opt"; then return 0; fi

  # Explicitly denied paths (other instances)
  for denied in $DENIED_PATHS; do
    if path_starts_with "$resolved" "$denied"; then
      echo "BLOCKED: $resolved is inside another Egregore instance ($denied)"
      return 1
    fi
  done

  # Allow instance registry (read-only, needed for multi-instance features)
  if path_starts_with "$resolved" "$HOME/.egregore"; then
    return 0
  fi

  # Allowed: project directory
  if [ -n "$PROJECT_DIR" ] && path_starts_with "$resolved" "$PROJECT_DIR"; then
    return 0
  fi

  # Allowed: memory directory (resolved symlink target)
  if [ -n "$MEMORY_DIR" ] && path_starts_with "$resolved" "$MEMORY_DIR"; then
    return 0
  fi

  # Allowed: managed repos
  for repo_path in $MANAGED_REPOS; do
    if path_starts_with "$resolved" "$repo_path"; then
      return 0
    fi
  done

  # Allowed: parent directory (for sibling repo operations like git clone)
  local parent_dir
  parent_dir="$(dirname "$PROJECT_DIR")"
  if path_starts_with "$resolved" "$parent_dir"; then
    # But NOT if it resolves into a denied path
    for denied in $DENIED_PATHS; do
      if path_starts_with "$resolved" "$denied"; then
        echo "BLOCKED: $resolved is inside another Egregore instance ($denied)"
        return 1
      fi
    done
    return 0
  fi

  # Default: block
  echo "BLOCKED: $resolved is outside the session boundary"
  return 1
}

# --- MODE: validate-repos ---
validate_repos() {
  local config="$SCRIPT_DIR/egregore.json"
  if [ ! -f "$config" ]; then
    return 0
  fi

  local repos
  repos=$(jq -r '(.repos[]? // empty) | if type == "object" then .name else . end' "$config" 2>/dev/null)
  local parent_dir
  parent_dir="$(dirname "$SCRIPT_DIR")"
  local exit_code=0

  for repo in $repos; do
    # Check for path traversal
    if [[ "$repo" == *".."* ]]; then
      echo "WARNING: repos[] entry '$repo' contains '..', skipping"
      exit_code=1
      continue
    fi

    # Check for absolute paths
    if [[ "$repo" == /* ]]; then
      echo "WARNING: repos[] entry '$repo' is an absolute path, skipping"
      exit_code=1
      continue
    fi

    # Resolve and check it stays under parent directory
    local resolved
    resolved=$(realpath "$parent_dir/$repo" 2>/dev/null || echo "")
    if [ -n "$resolved" ] && ! path_starts_with "$resolved" "$parent_dir"; then
      echo "WARNING: repos[] entry '$repo' resolves outside parent directory, skipping"
      exit_code=1
      continue
    fi
  done

  return $exit_code
}

# --- Consent surface -------------------------------------------------------
CONSENT_FILE="$SCRIPT_DIR/.egregore-boundary-consent"
PERSONAL_FILE="$SCRIPT_DIR/.egregore-boundary.local.json"

_boundary_locked() {
  local locked
  locked=$(jq -r '.boundary.locked // false' "$SCRIPT_DIR/egregore.json" 2>/dev/null || echo false)
  [ "$locked" = "true" ]
}

# Rewrite the cached boundary policy from the current config layers, so a grant
# is visible to the very next tool call instead of the next session.
refresh_boundary() {
  local hash boundary_file policy merged
  hash=$(echo -n "$SCRIPT_DIR" | md5 2>/dev/null || echo -n "$SCRIPT_DIR" | md5sum 2>/dev/null | cut -d' ' -f1)
  boundary_file="/tmp/egregore-boundary-${hash}.json"
  [ -f "$boundary_file" ] || return 0
  [ -f "$SCRIPT_DIR/bin/lib/boundary-policy.sh" ] || return 0
  # shellcheck source=bin/lib/boundary-policy.sh
  . "$SCRIPT_DIR/bin/lib/boundary-policy.sh"
  policy=$(boundary_policy_json "$SCRIPT_DIR" 2>/dev/null) || return 0
  [ -n "$policy" ] || return 0
  merged=$(jq -c --argjson p "$policy" '. + $p' "$boundary_file" 2>/dev/null) || return 0
  [ -n "$merged" ] || return 0
  printf '%s\n' "$merged" > "$boundary_file.$$.tmp" && mv -f "$boundary_file.$$.tmp" "$boundary_file"
}

# Parse `[--always] [--write] <dir>` into GRANT_DIR / GRANT_ALWAYS / GRANT_WRITE.
parse_grant_args() {
  GRANT_ALWAYS=false
  GRANT_WRITE=false
  GRANT_DIR=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --always|--persist) GRANT_ALWAYS=true ;;
      --write|--rw) GRANT_WRITE=true ;;
      --session) GRANT_ALWAYS=false ;;
      --)
        shift
        if [ -z "$GRANT_DIR" ] && [ $# -gt 0 ]; then GRANT_DIR="$1"; fi
        break
        ;;
      -*)
        echo "Unknown option: $1" >&2
        return 1
        ;;
      *)
        if [ -z "$GRANT_DIR" ]; then GRANT_DIR="$1"; fi
        ;;
    esac
    if [ $# -gt 0 ]; then shift; fi
  done
  if [ -z "$GRANT_DIR" ]; then
    echo "Usage: boundary.sh grant [--always] [--write] <dir>" >&2
    return 1
  fi
  GRANT_DIR=$(resolve_path "$GRANT_DIR")
  GRANT_DIR="${GRANT_DIR%/}"
  if [ -z "$GRANT_DIR" ]; then GRANT_DIR="/"; fi
  return 0
}

# Refuse the grants that must never be writable, whatever the caller intends.
assert_grantable() {
  local target="$1"
  load_boundary
  for denied in $DENIED_PATHS; do
    if path_starts_with "$target" "$denied"; then
      echo "REFUSED: $target belongs to another Egregore instance ($denied). This tier has no consent path." >&2
      return 2
    fi
  done
  if _boundary_locked; then
    echo "REFUSED: the org boundary is locked (egregore.json boundary.locked) — no consent path exists." >&2
    return 3
  fi
  case "$target" in
    /|"$HOME") echo "REFUSED: $target is too broad to grant." >&2; return 4 ;;
  esac
  return 0
}

grant_path() {
  parse_grant_args "$@" || return 1
  assert_grantable "$GRANT_DIR" || return $?

  if check_path "$GRANT_DIR" >/dev/null 2>&1; then
    echo "Already inside the boundary — no grant needed: $GRANT_DIR"
    return 0
  fi

  if [ "$GRANT_ALWAYS" = true ]; then
    local key="read" tmp
    [ "$GRANT_WRITE" = true ] && key="write"
    [ -f "$PERSONAL_FILE" ] || echo '{}' > "$PERSONAL_FILE"
    tmp="$PERSONAL_FILE.$$.tmp"
    jq --arg k "$key" --arg d "$GRANT_DIR" \
      '.[$k] = (((.[$k] // []) + [$d]) | unique)' "$PERSONAL_FILE" > "$tmp" \
      && mv -f "$tmp" "$PERSONAL_FILE"
    echo "Granted (persistent, $key): $GRANT_DIR"
    echo "  → $PERSONAL_FILE (gitignored, personal to you)"
  else
    touch "$CONSENT_FILE"
    if ! grep -qxF "$GRANT_DIR" "$CONSENT_FILE" 2>/dev/null; then
      printf '%s\n' "$GRANT_DIR" >> "$CONSENT_FILE"
    fi
    echo "Granted (this session): $GRANT_DIR"
    echo "  → $CONSENT_FILE (cleared at next session start)"
  fi

  refresh_boundary
  return 0
}

revoke_path() {
  parse_grant_args "$@" || return 1

  if [ "$GRANT_ALWAYS" = true ]; then
    local key="read" tmp
    [ "$GRANT_WRITE" = true ] && key="write"
    if [ -f "$PERSONAL_FILE" ]; then
      tmp="$PERSONAL_FILE.$$.tmp"
      jq --arg k "$key" --arg d "$GRANT_DIR" \
        '.[$k] = ((.[$k] // []) - [$d])' "$PERSONAL_FILE" > "$tmp" \
        && mv -f "$tmp" "$PERSONAL_FILE"
    fi
    echo "Revoked (persistent, $key): $GRANT_DIR"
  else
    if [ -f "$CONSENT_FILE" ]; then
      grep -vxF "$GRANT_DIR" "$CONSENT_FILE" > "$CONSENT_FILE.$$.tmp" 2>/dev/null || true
      mv -f "$CONSENT_FILE.$$.tmp" "$CONSENT_FILE"
    fi
    echo "Revoked (this session): $GRANT_DIR"
  fi

  refresh_boundary
  return 0
}

show_grants() {
  local hash boundary_file
  hash=$(echo -n "$SCRIPT_DIR" | md5 2>/dev/null || echo -n "$SCRIPT_DIR" | md5sum 2>/dev/null | cut -d' ' -f1)
  boundary_file="/tmp/egregore-boundary-${hash}.json"

  if _boundary_locked; then
    echo "posture: locked (egregore.json boundary.locked) — grants are void"
  elif [ -f "$boundary_file" ]; then
    echo "posture: $(jq -r '.posture // "standard"' "$boundary_file" 2>/dev/null)"
  else
    echo "posture: unknown (no cached boundary — session-start has not run)"
  fi

  echo ""
  echo "read roots:"
  jq -r '.read_roots[]? | "  " + .' "$boundary_file" 2>/dev/null || echo "  (none)"
  echo "write roots:"
  jq -r '.write_roots[]? | "  " + .' "$boundary_file" 2>/dev/null || echo "  (none)"
  echo "session grants:"
  if [ -s "$CONSENT_FILE" ]; then
    sed 's/^/  /' "$CONSENT_FILE"
  else
    echo "  (none)"
  fi
}

# --- Main ---
case "${1:-}" in
  check)
    if [ -z "${2:-}" ]; then
      echo "Usage: boundary.sh check <path>"
      exit 1
    fi
    check_path "$2"
    ;;
  validate-repos)
    validate_repos
    ;;
  grant)
    shift
    grant_path "$@"
    ;;
  revoke)
    shift
    revoke_path "$@"
    ;;
  grants)
    show_grants
    ;;
  refresh)
    refresh_boundary
    echo "Boundary policy refreshed."
    ;;
  *)
    echo "Usage: boundary.sh {check <path>|validate-repos|grant|revoke|grants|refresh}"
    exit 1
    ;;
esac
