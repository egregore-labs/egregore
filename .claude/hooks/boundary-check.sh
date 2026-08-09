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
#               cleared by session-start) or in config read/write roots.
# Posture (strict|standard|open), lock, and read/write roots are merged from
# egregore.json .boundary + .egregore-boundary.local.json by
# bin/lib/boundary-policy.sh and cached in the boundary JSON. The cache is
# re-merged in-process whenever either layer is newer than it, so a grant made
# mid-session takes effect on the very next tool call. Sessions running with
# permission_mode=bypassPermissions skip the soft tier (never the hard tier)
# unless the org boundary is locked.
#
# Two properties the soft tier depends on:
#   * The remedy must be reachable. `bin/boundary.sh grant <dir>` is exempt from
#     the soft-tier command scan — without that, every command that writes a
#     grant contains the very path it is granting and blocks itself.
#   * Only LOCAL paths are judged. Text a command hands to another host (an ssh
#     remote script, a docker/kubectl exec payload, an scp/rsync host:path) is
#     stripped before the soft-tier scan; those paths do not exist on this
#     machine. The hard tier still scans the whole command, unstripped.

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

BOUNDARY_JSON=$(cat "$BOUNDARY_FILE" 2>/dev/null) || exit 0

# --- Re-merge the policy layers when one of them changed since the cache ---
# The remedy this hook prints edits .egregore-boundary.local.json. Without this
# refresh that edit would not be observed until the next session — the user
# would follow the instructions and watch the identical block come back.
# Only the policy keys are recomputed; project/memory/repo/denied resolution
# stays session-start's job (it needs the instance registry and repo checkout).
refresh_policy_if_stale() {
  local personal="$PROJECT_DIR/.egregore-boundary.local.json"
  local org="$PROJECT_DIR/egregore.json"
  local lib="$PROJECT_DIR/bin/lib/boundary-policy.sh"
  local stale=""
  [ -f "$personal" ] && [ "$personal" -nt "$BOUNDARY_FILE" ] && stale=1
  [ -f "$org" ] && [ "$org" -nt "$BOUNDARY_FILE" ] && stale=1
  [ -n "$stale" ] || return 0
  [ -f "$lib" ] || return 0
  # shellcheck source=bin/lib/boundary-policy.sh
  . "$lib" 2>/dev/null || return 0
  local policy merged
  policy=$(boundary_policy_json "$PROJECT_DIR" 2>/dev/null) || return 0
  [ -n "$policy" ] || return 0
  merged=$(echo "$BOUNDARY_JSON" | jq -c --argjson p "$policy" '. + $p' 2>/dev/null) || return 0
  [ -n "$merged" ] || return 0
  BOUNDARY_JSON="$merged"
  # Persist so the next hook invocation is a plain cache read again. Best
  # effort: a failed write only costs another re-merge.
  printf '%s\n' "$merged" > "$BOUNDARY_FILE.$$.tmp" 2>/dev/null \
    && mv -f "$BOUNDARY_FILE.$$.tmp" "$BOUNDARY_FILE" 2>/dev/null
  rm -f "$BOUNDARY_FILE.$$.tmp" 2>/dev/null
  return 0
}
refresh_policy_if_stale 2>/dev/null || true

# Parse the boundary once. Empty fields carry a "-" sentinel: tab counts as IFS
# whitespace, so a genuinely empty @tsv field would collapse and shift every
# following field left.
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

# Write roots are opt-in only — never defaulted, never inherited from read
# roots. A locked org boundary voids the personal layer upstream in
# boundary-policy.sh, so nothing extra is needed here.
WRITE_ROOTS=$(echo "$BOUNDARY_JSON" | jq -r '.write_roots[]?' 2>/dev/null) || true

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
# Roots arrive newline-separated. Split on newlines only — macOS home
# directories routinely contain spaces ("~/Google Drive"), and word-splitting a
# root on spaces silently turns one grant into two useless prefixes.
_in_roots() {
  local resolved="$1" roots="$2" root
  [ -n "$roots" ] || return 1
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    if [[ "$resolved" == "$root" || "$resolved" == "$root/"* ]]; then
      return 0
    fi
  done <<< "$roots"
  return 1
}

in_read_roots() { _in_roots "$1" "$READ_ROOTS"; }
in_write_roots() { _in_roots "$1" "$WRITE_ROOTS"; }

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
  local resolved="$1" action="$2" dir always_flag=""
  # A session grant covers the directory outright; a persistent grant is split
  # read/write, so a write block has to ask for --write or the "always" option
  # produces a grant that does not unblock the retry.
  dir=$(dirname "$resolved")
  [ "$action" = "write" ] && always_flag=" --write"
  if [ "$LOCKED" = "true" ]; then
    echo "Environment isolation: $resolved is outside this instance's boundary and the org boundary is locked (egregore.json boundary.locked) — no consent path exists. Do not retry. Use AskUserQuestion with options: 'Paste contents inline' / 'Move the file into the repo and point me at the new path' / 'Cancel'." >&2
  else
    echo "Boundary consent needed: $resolved is outside this instance's $action surface (posture: $POSTURE). Do not retry yet and do not route around via other tools. Ask via AskUserQuestion with exactly these options: 'Allow $dir for this session' (on approval run: bash bin/boundary.sh grant \"$dir\") / 'Always allow on this instance' (on approval run: bash bin/boundary.sh grant --always${always_flag} \"$dir\") / 'Paste contents inline' / 'Cancel'. Then retry — the grant takes effect immediately. Never run a grant without the user's explicit approval in this exchange." >&2
  fi
  exit 2
}

# --- Helper: is this command the sanctioned grant, and nothing else? ---
# The remedy above necessarily names the very directory that is blocked, so
# without an exemption the fix blocks itself: a real deadlock, reproduced on
# 2026-08-09 trying to grant ~/.ssh. The exemption is narrow on purpose —
# the whole command must be one `bin/boundary.sh grant` invocation living
# inside this instance, with no chaining, redirection, or substitution, so it
# can never be used as a wrapper to smuggle a second command past the scan.
# It grants nothing by itself: boundary.sh refuses hard-tier and locked paths,
# and every later command is re-checked against the resulting grant.
is_grant_command() {
  local cmd="$1" script
  case "$cmd" in
    *[\;\|\&\<\>\`\(\)\{\}]*) return 1 ;;
    *$'\n'*) return 1 ;;
  esac
  local -a t=()
  read -r -a t <<< "$cmd"
  local i=0
  case "${t[0]:-}" in bash|sh|/bin/bash|/bin/sh|/usr/bin/env) i=1 ;; esac
  case "${t[$i]:-}" in bash|sh) [ "${t[0]:-}" = "/usr/bin/env" ] && i=$((i + 1)) ;; esac
  script="${t[$i]:-}"
  [ -n "$script" ] || return 1
  case "$script" in */boundary.sh|boundary.sh) ;; *) return 1 ;; esac
  [ "${t[$((i + 1))]:-}" = "grant" ] || return 1
  # The script has to be this instance's own boundary.sh — not some other
  # boundary.sh reachable on disk.
  local script_resolved
  script_resolved=$(resolve_path "$script")
  case "$script_resolved" in
    "$PROJECT_DIR"/*) return 0 ;;
  esac
  in_core_boundary "$script_resolved" || return 1
  return 0
}

# --- Helper: drop the parts of a command that execute on another host ---
# `ssh host1 "cat \$HOME/.appstate/x"` used to be blocked because $HOME resolved
# against the LOCAL home and landed outside the boundary — judging a remote path
# by local rules. Everything after an ssh host token, after a docker/kubectl
# exec target, and any `host:path` operand of scp/rsync runs elsewhere; strip it
# before the soft-tier scan. The hard tier still scans the raw command, so this
# can never open a path into another Egregore instance.
#
# The scanner state (_RS_*) is module-level rather than local because the
# per-token classifier is a separate function; a single command's worth of
# state is set up fresh by strip_remote_segments on every call.
_RS_OUT=""; _RS_TOK=""; _RS_POS=0; _RS_RUNNER=""
_RS_WANT_OPTVAL=0; _RS_STAGE=0; _RS_DROP=0

# Flush the current token into the local-only text, unless it is remote payload.
_rs_emit() {
  [ -n "$_RS_TOK" ] || return 0
  [ "$_RS_DROP" -eq 0 ] && _RS_OUT="$_RS_OUT $_RS_TOK"
  _RS_TOK=""
}

# Reset per-simple-command state at a `;` `|` `&` or newline.
_rs_reset() {
  _rs_emit
  _RS_POS=0; _RS_RUNNER=""; _RS_WANT_OPTVAL=0; _RS_STAGE=0; _RS_DROP=0
}

# Classify a finished token for the simple command being scanned.
_rs_classify() {
  local bare="$_RS_TOK" base
  bare="${bare%\"}"; bare="${bare#\"}"; bare="${bare%\'}"; bare="${bare#\'}"
  base="${bare##*/}"

  if [ "$_RS_DROP" -eq 1 ]; then
    _rs_emit
    return 0
  fi

  # Leading VAR=value assignments do not start the command word.
  if [ "$_RS_POS" -eq 0 ] && [[ "$bare" == [A-Za-z_]*=* ]]; then
    _rs_emit
    return 0
  fi

  if [ "$_RS_POS" -eq 0 ]; then
    case "$base" in
      # Wrappers: the real command word is still ahead, stay at position 0.
      sudo|env|command|nohup|time|timeout|stdbuf) _rs_emit; return 0 ;;
      ssh|slogin) _RS_RUNNER="ssh" ;;
      docker|podman) _RS_RUNNER="container" ;;
      kubectl) _RS_RUNNER="kubectl" ;;
      scp|rsync) _RS_RUNNER="copy" ;;
      *) _RS_RUNNER="" ;;
    esac
    _RS_POS=1
    _rs_emit
    return 0
  fi

  _RS_POS=$((_RS_POS + 1))

  case "$_RS_RUNNER" in
    ssh)
      if [ "$_RS_WANT_OPTVAL" -eq 1 ]; then
        # Option value such as `-i ~/.ssh/id_rsa` — a LOCAL path, keep scanning it.
        _RS_WANT_OPTVAL=0
        _rs_emit
      elif [[ "$bare" == -* ]]; then
        case "$bare" in
          -o|-i|-p|-l|-F|-J|-L|-R|-D|-b|-c|-E|-I|-m|-O|-Q|-S|-W|-w|-B) _RS_WANT_OPTVAL=1 ;;
        esac
        _rs_emit
      elif [ "$_RS_STAGE" -eq 0 ]; then
        # The host token. Everything after it is the remote script.
        _RS_STAGE=1
        _rs_emit
        _RS_DROP=1
      else
        _rs_emit
      fi
      return 0
      ;;
    container)
      if [ "$_RS_STAGE" -eq 2 ]; then
        _RS_DROP=1                # container/service consumed — rest is remote
        _rs_emit
        return 0
      fi
      case "$bare" in
        exec) [ "$_RS_STAGE" -eq 0 ] && _RS_STAGE=1 ;;
        -*) : ;;
        *) [ "$_RS_STAGE" -eq 1 ] && _RS_STAGE=2 ;;
      esac
      _rs_emit
      return 0
      ;;
    kubectl)
      if [ "$bare" = "--" ]; then
        _rs_emit
        _RS_DROP=1
        return 0
      fi
      _rs_emit
      return 0
      ;;
    copy)
      # scp/rsync mix local and remote operands. Only `host:path` operands are
      # remote; a bare path is local and must still be scanned.
      if [[ "$bare" != /* && "$bare" == *:* && "${bare%%:*}" != */* ]]; then
        _RS_TOK=""
        return 0
      fi
      _rs_emit
      return 0
      ;;
  esac

  _rs_emit
}

strip_remote_segments() {
  local cmd="$1" q="" ch i
  _RS_OUT=""; _RS_TOK=""; _RS_POS=0; _RS_RUNNER=""
  _RS_WANT_OPTVAL=0; _RS_STAGE=0; _RS_DROP=0

  for ((i = 0; i < ${#cmd}; i++)); do
    ch="${cmd:i:1}"

    if [ -n "$q" ]; then
      [ "$ch" = "$q" ] && q=""
      _RS_TOK="$_RS_TOK$ch"
      continue
    fi

    case "$ch" in
      \'|\") q="$ch"; _RS_TOK="$_RS_TOK$ch"; continue ;;
      \\) i=$((i + 1)); _RS_TOK="$_RS_TOK${cmd:i:1}"; continue ;;
      ';'|'|'|'&'|$'\n') _rs_reset; continue ;;
      '<'|'>')
        # A redirection target is local even on an ssh line.
        _rs_emit
        _RS_DROP=0
        continue
        ;;
      ' '|$'\t')
        [ -n "$_RS_TOK" ] && _rs_classify
        continue
        ;;
    esac
    _RS_TOK="$_RS_TOK$ch"
  done
  [ -n "$_RS_TOK" ] && _rs_classify

  printf '%s' "${_RS_OUT# }"
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
    # Read roots and posture=open grant reads only — writes need an explicit
    # write grant (boundary.write[] / `grant --write`), a session consent line,
    # or a bypassPermissions session. Under a lock the personal layer and the
    # consent file are already void upstream, so only org write[] survives.
    [ "$RELAXED" = "true" ] && exit 0
    in_write_roots "$RESOLVED" && exit 0
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

    # The sanctioned grant is exempt — it necessarily names the blocked path,
    # so scanning it would make the documented remedy unreachable.
    is_grant_command "$COMMAND" && exit 0

    # Judge local paths only: text destined for another host is stripped first.
    LOCAL_TEXT=$(strip_remote_segments "$COMMAND" 2>/dev/null) || LOCAL_TEXT="$COMMAND"

    CANDIDATES=$(echo "$LOCAL_TEXT" | grep -oE '(~|\$HOME|/Users/[A-Za-z0-9._-]+)/[A-Za-z0-9._/-]+' 2>/dev/null | sort -u | head -20) || true
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
