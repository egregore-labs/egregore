#!/usr/bin/env bash
set -euo pipefail

# settings.sh — deterministic config verbs for an Egregore instance.
#
# Edits egregore.json atomically. No agent, no network, no session. Idempotent:
# re-adding an existing item is a no-op success; removing a missing one is too.
# This is the deterministic core the launcher settings screen (and slash
# commands) call — the reliability lives here, the surfaces are thin callers.
#
# Usage:
#   settings.sh hosting status|on|off
#   settings.sh relay status|on|off
#   settings.sh repo list | add <name> [description] | remove <name>
#   settings.sh admin list | add <github-handle> | remove <github-handle>
#   settings.sh dump                 # full settings snapshot as JSON (for the launcher)
#
# Add --json to a read verb (status/list) for machine-readable output.
#
# Exit codes: 0 ok · 1 usage/validation error · 2 config not found.

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$SCRIPT_DIR/egregore.json"

# ── helpers ──────────────────────────────────────────────────────────────

_die() { echo "$1" >&2; exit "${2:-1}"; }

_valid_token() {
  # non-empty, GitHub-handle / repo-name safe charset
  [ -n "${1:-}" ] && printf '%s' "$1" | grep -qE '^[A-Za-z0-9._-]+$'
}

_save() {
  # _save '<jq-filter>' [jq-args...] — apply filter to CONFIG, write atomically.
  local filter="$1"; shift
  local tmp
  tmp="$(mktemp "$CONFIG.XXXXXX")" || _die "cannot create temp file" 1
  if jq "$@" "$filter" "$CONFIG" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    mv "$tmp" "$CONFIG"
  else
    rm -f "$tmp"
    _die "failed to update $CONFIG (invalid jq filter or unwritable file)" 1
  fi
}

_has_repo() { jq -e --arg n "$1" 'any(.repos[]?; (if type=="object" then .name else . end) == $n)' "$CONFIG" >/dev/null; }
_has_admin() { jq -e --arg h "$1" 'any(.admins[]?; . == $h)' "$CONFIG" >/dev/null; }

usage() {
  cat >&2 <<'EOF'
settings.sh — Egregore instance settings

  settings.sh hosting status|on|off
  settings.sh relay  status|on|off
  settings.sh repo   list | add <name> [description] | remove <name>
  settings.sh admin  list | add <github-handle> | remove <github-handle>
  settings.sh people list | add <github-handle> | remove <github-handle>
  settings.sh dump                         full snapshot (JSON)

  --json    machine-readable output for status/list
EOF
  exit "${1:-1}"
}

# ── verbs ────────────────────────────────────────────────────────────────

cmd_hosting() {
  local action="${1:-status}"
  # NEVER use jq's `// "true"` here: `//` treats an explicit `false` as empty and
  # would return the default, silently defeating the off-switch. Test `!= false`
  # so absent/true => enabled, explicit false => disabled. `enabled` is the
  # resolved boolean string ("true"/"false").
  local enabled; enabled="$(jq -r '.features.publishing != false' "$CONFIG" 2>/dev/null || echo "true")"
  case "$action" in
    status)
      if [ "$JSON" = 1 ]; then
        jq -n --argjson on "$enabled" '{domain:"hosting", publishing:$on}'
      elif [ "$enabled" = "false" ]; then echo "Hosting (egregore.xyz): OFF"
      else echo "Hosting (egregore.xyz): ON"; fi ;;
    on)
      _save '.features.publishing = true'
      echo "Hosting (egregore.xyz): ON" ;;
    off)
      _save '.features.publishing = false'
      echo "Hosting (egregore.xyz): OFF — artifacts will no longer upload to egregore.xyz" ;;
    *) _die "usage: settings.sh hosting status|on|off" 1 ;;
  esac
}

# The public share relay is the only upload route when there is no org API
# key. It is unauthenticated, readable by anyone with the URL, and expires
# after 7 days, so it is OFF unless explicitly enabled.
cmd_relay() {
  local action="${1:-status}"
  local enabled; enabled="$(jq -r 'if .features.public_relay == true then "true" else "false" end' "$CONFIG" 2>/dev/null || echo "false")"
  case "$action" in
    status)
      if [ "$JSON" = 1 ]; then
        jq -n --argjson on "$enabled" '{domain:"relay", public_relay:$on}'
      elif [ "$enabled" = "true" ]; then
        echo "Public share relay: ON — artifacts published without an org API key upload to a public, unauthenticated URL (expires after 7 days)"
      else
        echo "Public share relay: OFF — without an org API key, nothing uploads anywhere"
      fi ;;
    on)
      _save '.features.public_relay = true'
      echo "Public share relay: ON"
      echo "  Artifacts published without an org API key now upload to a public, unauthenticated URL that anyone with the link can read for 7 days." ;;
    off)
      _save '.features.public_relay = false'
      echo "Public share relay: OFF — without an org API key, nothing uploads anywhere" ;;
    *) _die "usage: settings.sh relay status|on|off" 1 ;;
  esac
}

cmd_repo() {
  local action="${1:-list}"; shift || true
  case "$action" in
    list)
      if [ "$JSON" = 1 ]; then
        jq '[.repos[]? | if type=="object" then . else {name:.} end]' "$CONFIG"
      else
        jq -r '.repos[]? | if type=="object" then "  " + .name + (if .description then " — " + .description else "" end) else "  " + . end' "$CONFIG"
      fi ;;
    add)
      local name="${1:-}"; shift || true
      local desc="${*:-}"
      _valid_token "$name" || _die "usage: settings.sh repo add <name> [description]" 1
      if _has_repo "$name"; then echo "repo '$name' already managed"; return 0; fi
      if [ -n "$desc" ]; then
        _save '.repos = ((.repos // []) + [{name:$n, description:$d}])' --arg n "$name" --arg d "$desc"
      else
        _save '.repos = ((.repos // []) + [{name:$n}])' --arg n "$name"
      fi
      echo "added repo '$name'"
      echo "  clone it with: /sync-repos  (or reopen the egregore)" ;;
    remove)
      local name="${1:-}"
      _valid_token "$name" || _die "usage: settings.sh repo remove <name>" 1
      if ! _has_repo "$name"; then echo "repo '$name' is not managed"; return 0; fi
      _save '.repos = [.repos[]? | select((if type=="object" then .name else . end) != $n)]' --arg n "$name"
      echo "removed repo '$name' from config"
      echo "  note: the local ../$name checkout is left untouched" ;;
    *) _die "usage: settings.sh repo list|add|remove" 1 ;;
  esac
}

cmd_admin() {
  local action="${1:-list}"; shift || true
  case "$action" in
    list)
      if [ "$JSON" = 1 ]; then jq '{admins:(.admins // [])}' "$CONFIG"
      else jq -r '.admins[]? | "  " + .' "$CONFIG"; fi ;;
    add)
      local h="${1:-}"
      _valid_token "$h" || _die "usage: settings.sh admin add <github-handle>" 1
      if _has_admin "$h"; then echo "'$h' is already an admin"; return 0; fi
      _save '.admins = ((.admins // []) + [$h])' --arg h "$h"
      echo "added admin '$h'" ;;
    remove)
      local h="${1:-}"
      _valid_token "$h" || _die "usage: settings.sh admin remove <github-handle>" 1
      if ! _has_admin "$h"; then echo "'$h' is not an admin"; return 0; fi
      local count; count="$(jq '(.admins // []) | length' "$CONFIG")"
      [ "$count" -le 1 ] && _die "refusing to remove the last admin ('$h') — add another admin first" 1
      _save '.admins = [.admins[]? | select(. != $h)]' --arg h "$h"
      echo "removed admin '$h'" ;;
    *) _die "usage: settings.sh admin list|add|remove" 1 ;;
  esac
}

# ── people ───────────────────────────────────────────────────────────────
# People live as files in memory/people/. add/remove manage that directory AND
# GitHub repo access (the meaningful local grant). Connected-mode extras — the
# invite link + Telegram (/invite) and Supabase/Neo4j teardown (/delete-user) —
# are pointed to, not duplicated here.

_people_dir() { echo "$SCRIPT_DIR/memory/people"; }

_people_names() {
  local pdir; pdir="$(_people_dir)"
  [ -d "$pdir" ] || return 0
  ls "$pdir"/*.md 2>/dev/null | while IFS= read -r f; do basename "$f" .md; done \
    | grep -viE '^(index|readme)$' || true
}

_people_json() {
  local names; names="$(_people_names)"
  if [ -z "$names" ]; then echo '[]'; return; fi
  printf '%s\n' "$names" | jq -R . | jq -sc 'map(select(length>0))'
}

_has_person() { [ -f "$(_people_dir)/$1.md" ]; }

# add|remove a GitHub push-collaborator across the instance's repos. Best-effort:
# no token/org => skip with a note; per-repo failures never abort.
_people_github() {
  local user="$1" op="$2" token org repos r
  token="$(grep '^GITHUB_TOKEN=' "$SCRIPT_DIR/.env" 2>/dev/null | cut -d= -f2- || true)"
  org="$(jq -r '.github_org // empty' "$CONFIG" 2>/dev/null)"
  if [ -z "$token" ] || [ -z "$org" ]; then
    echo "  (no GitHub token/org — skipped repo access; run bin/github-auth.sh)" >&2
    return 0
  fi
  repos="$(jq -r '[.repo_name, (.memory_repo // "" | split("/") | last | sub("\\.git$";"")), (.repos[]? | if type=="object" then .name else . end)] | map(select(. != null and . != "")) | unique | .[]' "$CONFIG" 2>/dev/null)"
  for r in $repos; do
    if [ "$op" = "add" ]; then
      curl -s -o /dev/null -X PUT -H "Authorization: Bearer $token" -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/$org/$r/collaborators/$user" -d '{"permission":"push"}' 2>/dev/null || true
    else
      curl -s -o /dev/null -X DELETE -H "Authorization: Bearer $token" -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/$org/$r/collaborators/$user" 2>/dev/null || true
    fi
  done
}

# create|remove memory/people/<user>.md, committing ONLY the people dir.
_people_file() {
  local user="$1" op="$2" pdir f inviter today
  pdir="$(_people_dir)"
  [ -d "$SCRIPT_DIR/memory" ] || { echo "  (no memory dir — skipped person file)" >&2; return 0; }
  mkdir -p "$pdir"
  f="$pdir/$user.md"
  if [ "$op" = "add" ]; then
    if [ ! -f "$f" ]; then
      inviter="$(jq -r '.display_name // .github_username // "admin"' "$SCRIPT_DIR/.egregore-state.json" 2>/dev/null || echo admin)"
      today="$(date -u +%Y-%m-%d)"
      printf -- '---\nname: %s\nperson_id: github-login:%s\ngithub: %s\ninvited_by: %s\njoined: %s\n---\n' "$user" "$(printf '%s' "$user" | tr '[:upper:]' '[:lower:]')" "$user" "$inviter" "$today" > "$f"
    fi
  else
    rm -f "$f"
  fi
  ( cd "$SCRIPT_DIR/memory" 2>/dev/null && git add -A people/ 2>/dev/null \
      && git commit -q -m "chore(settings): $op $user in people" 2>/dev/null \
      && git push -q 2>/dev/null ) || true
}

cmd_people() {
  local action="${1:-list}"; shift || true
  case "$action" in
    list)
      if [ "$JSON" = 1 ]; then _people_json
      else
        local names; names="$(_people_names)"
        if [ -n "$names" ]; then printf '  %s\n' $names; else echo "    (none)"; fi
      fi ;;
    add)
      local h="${1:-}"
      _valid_token "$h" || _die "usage: settings.sh people add <github-handle>" 1
      if _has_person "$h"; then echo "'$h' is already in people"; return 0; fi
      _people_github "$h" "add"
      _people_file "$h" "add"
      echo "added '$h' (repo access + person file)"
      [ -n "$(jq -r '.api_url // empty' "$CONFIG" 2>/dev/null)" ] && echo "  connected org: for the invite link + Telegram, run /invite $h" ;;
    remove)
      local h="${1:-}"
      _valid_token "$h" || _die "usage: settings.sh people remove <github-handle>" 1
      if ! _has_person "$h"; then echo "'$h' is not in people"; return 0; fi
      _people_github "$h" "remove"
      _people_file "$h" "remove"
      echo "removed '$h' (repo access + person file)"
      [ -n "$(jq -r '.api_url // empty' "$CONFIG" 2>/dev/null)" ] && echo "  connected org: for full deprovision (Supabase/Neo4j), run /delete-user $h" ;;
    *) _die "usage: settings.sh people list|add|remove" 1 ;;
  esac
}

cmd_dump() {
  # Always JSON — the launcher calls this once to render the whole settings screen.
  local people; people="$(_people_json)"
  jq --argjson people "$people" '{
    org: .org_name,
    slug: .slug,
    hosting: (.features.publishing != false),
    public_relay: (.features.public_relay == true),
    repos: [.repos[]? | if type=="object" then . else {name:.} end],
    admins: (.admins // []),
    people: $people
  }' "$CONFIG"
}

# ── dispatch ─────────────────────────────────────────────────────────────

[ -f "$CONFIG" ] || _die "egregore.json not found at $CONFIG" 2

# Pull out --json (bash 3.2-safe array handling), leave the rest as positionals.
JSON=0
_args=()
for _a in "$@"; do
  if [ "$_a" = "--json" ]; then JSON=1; else _args+=("$_a"); fi
done
set -- "${_args[@]+"${_args[@]}"}"

DOMAIN="${1:-}"; shift || true
case "$DOMAIN" in
  hosting) cmd_hosting "$@" ;;
  relay)   cmd_relay "$@" ;;
  repo)    cmd_repo "$@" ;;
  admin)   cmd_admin "$@" ;;
  people)  cmd_people "$@" ;;
  dump)    cmd_dump ;;
  ""|-h|--help|help) usage 0 ;;
  *) _die "unknown settings domain: '$DOMAIN' (try: hosting, relay, repo, admin, people, dump)" 1 ;;
esac
