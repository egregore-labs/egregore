# shellcheck shell=bash
# permissions.sh — Soft-enforced admin-only access for Egregore content.
#
# Content can be marked admin-only via frontmatter:
#
#     ---
#     admin: true
#     ---
#
# Admins are listed in egregore.json under "admins": ["github1", "github2", ...].
#
# Two enforcement layers:
#
#  - Read-side (CLI listings, /view rendering) — soft, tag-not-hide:
#    admin entries appear in /activity and /dashboard listings tagged so admins
#    can identify them at a glance. For non-admins the title/topic/branch are
#    replaced with an opaque "[admin]" placeholder — they see admin work
#    exists but the topic doesn't leak. Anyone with git access still bypasses
#    by `cat`-ing the file.
#
#  - Publish-side (egregore.xyz upload) — strict: publish-artifact.sh refuses
#    to push admin-only files because egregore.xyz URLs are not auth-gated.
#    Override with --allow-admin (set by /view after explicit user
#    confirmation via AskUserQuestion).

# Get list of admin GitHub usernames (newline-separated, lowercase)
_get_admins() {
  local config="${CONFIG:-${SCRIPT_DIR:-$(pwd)}/egregore.json}"
  if [ -f "$config" ]; then
    jq -r '.admins[]? // empty' "$config" 2>/dev/null | tr '[:upper:]' '[:lower:]'
  fi
}

# Returns 0 if username is an admin, 1 otherwise. Empty username = not admin.
_is_admin() {
  local username="${1:-}"
  [ -z "$username" ] && return 1
  local lc
  lc=$(printf '%s' "$username" | tr '[:upper:]' '[:lower:]')
  _get_admins | grep -qx "$lc"
}

# Returns 0 if the file's frontmatter contains `admin: true`, 1 otherwise.
# Tolerates whitespace and case in the value. Looks at the first ~60 lines
# to keep the scan bounded.
_is_admin_only_file() {
  local path="$1"
  [ -f "$path" ] || return 1
  awk '
    BEGIN { in_fm = 0; found = 0 }
    NR == 1 && /^---[[:space:]]*$/ { in_fm = 1; next }
    in_fm && /^---[[:space:]]*$/ { exit (found ? 0 : 1) }
    in_fm && tolower($0) ~ /^admin:[[:space:]]*true[[:space:]]*$/ { found = 1 }
    NR > 60 { exit (found ? 0 : 1) }
    END { exit (found ? 0 : 1) }
  ' "$path" 2>/dev/null
}

# Returns 0 if the file's frontmatter has the `admin:` key set at all (true or
# false), 1 otherwise. Used by the admin-content-detector hook to skip files
# whose admin status was already decided — including an explicit `admin: false`
# meaning "reviewed, public on purpose". Without this, the hook would re-prompt
# on every edit of a sensitive-keyword file the user has already cleared.
_has_admin_decision() {
  local path="$1"
  [ -f "$path" ] || return 1
  awk '
    BEGIN { in_fm = 0; found = 0 }
    NR == 1 && /^---[[:space:]]*$/ { in_fm = 1; next }
    in_fm && /^---[[:space:]]*$/ { exit (found ? 0 : 1) }
    in_fm && tolower($0) ~ /^admin:[[:space:]]*(true|false)[[:space:]]*$/ { found = 1 }
    NR > 60 { exit (found ? 0 : 1) }
    END { exit (found ? 0 : 1) }
  ' "$path" 2>/dev/null
}

# Resolve current user's GitHub username (lowercase). Falls back through:
#   $1 → .egregore-state.json → git user.name
_current_user() {
  local explicit="${1:-}"
  if [ -n "$explicit" ]; then
    printf '%s' "$explicit" | tr '[:upper:]' '[:lower:]'
    return 0
  fi
  local state="${SCRIPT_DIR:-$(pwd)}/.egregore-state.json"
  if [ -f "$state" ]; then
    local u
    u=$(jq -r '.github_username // empty' "$state" 2>/dev/null)
    if [ -n "$u" ]; then
      printf '%s' "$u" | tr '[:upper:]' '[:lower:]'
      return 0
    fi
  fi
  git config user.name 2>/dev/null | tr '[:upper:]' '[:lower:]'
}

# Returns 0 if the file's body contains sensitive keywords (fundraising, legal,
# personnel, strategic). Used by the admin-content-detector hook to flag files
# that probably should be admin-only but aren't yet. Whole-word match on a
# short curated list — easy to extend without retraining intuition.
_looks_sensitive() {
  local path="$1"
  [ -f "$path" ] || return 1
  # Word-boundary regex (case-insensitive). Keep this list curated, not exhaustive.
  grep -qiE '\b(fundrais(e|ing)|term[ -]?sheet|cap[ -]?table|valuation|runway|investor|VC[s]?|raise|seed[ -]?round|series[ -][a-d]|board[ -]prep|equity[ -]grant|stock[ -]option|RSU|salary|compensation|payroll|severance|PIP|NDA|attorney|legal[ -]hold|lawsuit|acquisition|merger|due[ -]diligence)\b' "$path"
}
