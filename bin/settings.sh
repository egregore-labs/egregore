#!/usr/bin/env bash
set -euo pipefail

# settings.sh — deterministic config verbs for an Egregore instance.
#
# Edits egregore.json atomically. No agent, no session. Idempotent: re-adding
# an existing item is a no-op success; removing a missing one is too. Switching
# to staged releases is the one networked verb: it creates origin/develop first.
# This is the deterministic core the launcher settings screen (and slash
# commands) call — the reliability lives here, the surfaces are thin callers.
#
# Usage:
#   settings.sh hosting status|on|off
#   settings.sh relay status|on|off
#   settings.sh workflow status|simple|staged
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
    _control_plane_push
  else
    rm -f "$tmp"
    _die "failed to update $CONFIG (invalid jq filter or unwritable file)" 1
  fi
}

# ── control-plane push (Connected mode) ──────────────────────────────────
# A confirmed settings write reaches the control plane immediately — no
# harness session, no git ceremony in the loop. Fail-soft: the file write
# already landed, and a missed push is reconciled by the next session
# start's settings sync (bin/lib/settings-drift.sh).
_control_plane_push() {
  local api_url api_key payload actor response revision
  api_url=$(jq -r '.api_url // empty' "$CONFIG" 2>/dev/null)
  [ -n "$api_url" ] || return 0
  api_key=$(grep '^EGREGORE_API_KEY=' "$SCRIPT_DIR/.env" 2>/dev/null | cut -d'=' -f2-)
  [ -n "$api_key" ] || return 0
  actor=$(jq -r '.github_username // empty' "$SCRIPT_DIR/.egregore-state.json" 2>/dev/null)
  payload=$(jq -c --arg by "$actor" '{
    settings: ({boundary, base_branch, people_removed, features, repos, admins, people}
      | with_entries(select(.value != null))),
    updated_by: (if $by == "" then null else $by end)
  }' "$CONFIG" 2>/dev/null)
  [ -n "$payload" ] || return 0
  response=$(curl -s --max-time 10 -X PUT "$api_url/api/org/settings" \
    -H "Authorization: Bearer $api_key" -H "Content-Type: application/json" \
    --data-binary "$payload" 2>/dev/null) || return 0
  revision=$(printf '%s' "$response" | jq -r '.settings_revision // empty' 2>/dev/null)
  if [ -n "$revision" ] && [ -f "$SCRIPT_DIR/.egregore-state.json" ]; then
    local st
    st="$(mktemp "$SCRIPT_DIR/.egregore-state.json.XXXXXX")" || return 0
    if jq --arg rev "$revision" '.org_settings_revision = $rev' "$SCRIPT_DIR/.egregore-state.json" > "$st" 2>/dev/null && [ -s "$st" ]; then
      mv "$st" "$SCRIPT_DIR/.egregore-state.json"
    else
      rm -f "$st"
    fi
  fi
  return 0
}

_has_repo() { jq -e --arg n "$1" 'any(.repos[]?; (if type=="object" then .name else . end) == $n)' "$CONFIG" >/dev/null; }
_has_admin() { jq -e --arg h "$1" 'any(.admins[]?; . == $h)' "$CONFIG" >/dev/null; }

usage() {
  cat >&2 <<'EOF'
settings.sh — Egregore instance settings

  settings.sh hosting status|on|off
  settings.sh relay  status|on|off
  settings.sh workflow status|simple|staged
  settings.sh repo   list | add <name> [description] | remove <name>
  settings.sh admin  list | add <github-handle> | remove <github-handle>
  settings.sh people list | add <github-handle> | remove <github-handle>
  settings.sh posture status|strict|standard|open   org-wide boundary posture
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

cmd_workflow() {
  local action="${1:-status}"
  local base
  base="$(jq -r 'if has("base_branch") then .base_branch else "develop" end' "$CONFIG" 2>/dev/null)"
  case "$action" in
    status)
      local workflow="custom"
      [ "$base" = "main" ] && workflow="simple"
      [ "$base" = "develop" ] && workflow="staged"
      if [ "$JSON" = 1 ]; then
        jq -n --arg workflow "$workflow" --arg base_branch "$base" \
          '{domain:"workflow", workflow:$workflow, base_branch:$base_branch}'
      elif [ "$workflow" = "simple" ]; then
        echo "Git workflow: SIMPLE — pull requests target main"
      elif [ "$workflow" = "staged" ]; then
        echo "Git workflow: STAGED — pull requests target develop; releases promote to main"
      else
        echo "Git workflow: CUSTOM — pull requests target $base"
      fi
      ;;
    simple)
      if [ "$base" != "main" ]; then
        git -C "$SCRIPT_DIR" rev-parse --git-dir >/dev/null 2>&1 \
          || _die "cannot switch workflow: $SCRIPT_DIR is not a Git repository" 1
        git -C "$SCRIPT_DIR" ls-remote --exit-code --heads origin main >/dev/null 2>&1 \
          || _die "cannot switch workflow: origin/main does not exist or could not be reached" 1
        _save '.base_branch = "main"'
      fi
      echo "Git workflow: SIMPLE — pull requests now target main · /save shares it with the org"
      ;;
    staged)
      if [ "$base" != "develop" ]; then
        git -C "$SCRIPT_DIR" rev-parse --git-dir >/dev/null 2>&1 \
          || _die "cannot switch workflow: $SCRIPT_DIR is not a Git repository" 1
        bash "$SCRIPT_DIR/bin/lib/ensure-develop.sh" "$SCRIPT_DIR" >/dev/null \
          || _die "could not create develop; workflow is unchanged" 1
        git -C "$SCRIPT_DIR" ls-remote --exit-code --heads origin develop >/dev/null 2>&1 \
          || _die "could not verify origin/develop; workflow is unchanged" 1
        _save '.base_branch = "develop"'
      elif ! jq -e 'has("base_branch")' "$CONFIG" >/dev/null 2>&1; then
        _save '.base_branch = "develop"'
      fi
      echo "Git workflow: STAGED — pull requests now target develop; releases promote to main · /save shares it with the org"
      ;;
    *) _die "usage: settings.sh workflow status|simple|staged" 1 ;;
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
  # Removals are durable: sessions and syncs can resurrect person FILES
  # (observed: deleted members reappearing via session auto-saves), so the
  # committed removal ledger in egregore.json, not file presence, decides
  # who is listed. `people add` clears the tombstone.
  local removed; removed="$(jq -r '(.people_removed // [])[] | ascii_downcase' "$CONFIG" 2>/dev/null | sort -u)"
  ls "$pdir"/*.md 2>/dev/null | while IFS= read -r f; do
      # Alias witness files (Alias-Of: other.md) are presentation metadata
      # for an existing member, not members themselves — one person, one row.
      if head -8 "$f" 2>/dev/null | grep -q '^Alias-Of:[[:space:]]*[^[:space:]]'; then
        continue
      fi
      basename "$f" .md
    done \
    | grep -viE '^(index|readme)$' \
    | while IFS= read -r name; do
        if [ -n "$removed" ] && printf '%s\n' "$removed" | grep -qxF "$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"; then
          continue
        fi
        printf '%s\n' "$name"
      done || true
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
      _save '.people_removed = ((.people_removed // []) | map(select(ascii_downcase != ($h | ascii_downcase)))) | if .people_removed == [] then del(.people_removed) else . end' --arg h "$h"
      if _has_person "$h"; then echo "'$h' is already in people"; return 0; fi
      _people_github "$h" "add"
      _people_file "$h" "add"
      echo "added '$h' (repo access + person file)"
      [ -n "$(jq -r '.api_url // empty' "$CONFIG" 2>/dev/null)" ] && echo "  connected org: for the invite link + Telegram, run /invite $h" ;;
    remove)
      local h="${1:-}"
      _valid_token "$h" || _die "usage: settings.sh people remove <github-handle>" 1
      # Tombstone first: the removal ledger in committed org config keeps a
      # removal durable even when a person file is later resurrected by a
      # session write or sync.
      _save '.people_removed = ((.people_removed // []) + [$h] | map(ascii_downcase) | unique)' --arg h "$h"
      if ! _has_person "$h"; then echo "'$h' is not in people (removal recorded)"; return 0; fi
      _people_github "$h" "remove"
      _people_file "$h" "remove"
      echo "removed '$h' (repo access + person file + durable removal record)"
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
    workflow: (
      if ((if has("base_branch") then .base_branch else "develop" end) == "main") then "simple"
      elif ((if has("base_branch") then .base_branch else "develop" end) == "develop") then "staged"
      else "custom"
      end
    ),
    base_branch: (if has("base_branch") then .base_branch else "develop" end),
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

# ── privacy & access (read snapshot) ─────────────────────────────────────
# One composed JSON for the Settings Privacy & access panel. Identity,
# membership, and capability values come from the Runtime authorization
# backend (access-status); this shell layer adds only committed boundary
# config, the personal boundary-local file, isolation state, and honest
# constant statements. Never includes secrets, tokens, or internal paths.

_md5() { if command -v md5 >/dev/null 2>&1; then md5 -q -s "$1" 2>/dev/null || printf '%s' "$1" | md5; else printf '%s' "$1" | md5sum | cut -d' ' -f1; fi; }

_graph_retrieval_state() {
  # Mirrors bin/search.sh: activation record keyed sha256(org_id|main)[:16].
  local org main gitdir key record
  org=$(jq -r '.org_id // empty' "$CONFIG" 2>/dev/null)
  [ -n "$org" ] || { echo "unknown"; return; }
  main="$SCRIPT_DIR"
  if [ -f "$SCRIPT_DIR/.git" ]; then
    gitdir=$(sed -n 's/^gitdir: //p' "$SCRIPT_DIR/.git" 2>/dev/null)
    case "$gitdir" in */.git/worktrees/*) main="${gitdir%/.git/worktrees/*}" ;; esac
  fi
  main=$(cd "$main" 2>/dev/null && pwd -P) || { echo "unknown"; return; }
  key=$(printf '%s|%s' "$org" "$main" | shasum -a 256 2>/dev/null | cut -c1-16)
  record="${EGREGORE_UPGRADE_ROOT:-$HOME/.egregore/runtime/upgrade}/${key}/active.json"
  if [ -f "$record" ] && [ "$(jq -r '.retrieval // empty' "$record" 2>/dev/null)" = "runtime-qmd" ]; then
    echo "not-used-by-this-runtime"
  else
    echo "legacy"
  fi
}

cmd_privacy() {
  local access posture locked org_reads personal_reads denied digest graph
  access=$(cd "$SCRIPT_DIR" && EGREGORE_ROOT="$SCRIPT_DIR" \
    PYTHONSAFEPATH=1 PYTHONPATH="$SCRIPT_DIR${PYTHONPATH:+:$PYTHONPATH}" \
    python3 -m egregore_runtime.harness_cli access-status 2>/dev/null) || true
  printf '%s' "$access" | jq -e . >/dev/null 2>&1 || access='{"status":"attention"}'
  posture=$(jq -r '.boundary.posture // "standard"' "$CONFIG" 2>/dev/null || echo standard)
  locked=$(jq -r 'if (.boundary.locked // false) == true then "true" else "false" end' "$CONFIG" 2>/dev/null || echo false)
  org_reads=$(jq -c '.boundary.read // []' "$CONFIG" 2>/dev/null || echo '[]')
  personal_reads=$(jq -c '.read // []' "$SCRIPT_DIR/.egregore-boundary.local.json" 2>/dev/null || echo '[]')
  digest=$(_md5 "$SCRIPT_DIR")
  denied=$(jq -r '.denied_paths | length' "/tmp/egregore-boundary-${digest}.json" 2>/dev/null || echo 0)
  graph=$(_graph_retrieval_state)
  jq -n \
    --argjson access "$access" \
    --arg posture "$posture" \
    --argjson locked "$locked" \
    --argjson org_reads "$org_reads" \
    --argjson personal_reads "$personal_reads" \
    --argjson denied "${denied:-0}" \
    --arg graph "$graph" \
    '{
      access: $access,
      boundary: {
        posture: $posture,
        locked: $locked,
        org_read_roots: $org_reads,
        personal_read_roots: $personal_reads
      },
      isolation: { foreign_instances_denied: $denied },
      graph_retrieval: $graph,
      content_protection: {
        admin_marked: "hidden on Egregore surfaces from non-admin members",
        external_publication: "admin-marked content blocked unless an authorized admin separately confirms",
        raw_repository_access: "organization-wide",
        per_document_filesystem_acl: "not enabled"
      }
    }'
}

# ── boundary posture (org-wide) ──────────────────────────────────────────
# Edits committed egregore.json for the whole organization. `locked: true`
# removes the change path entirely — posture is then org-policy managed.

cmd_posture() {
  local action="${1:-status}" current
  current="$(jq -r '.boundary.posture // "standard"' "$CONFIG" 2>/dev/null || echo standard)"
  case "$current" in strict|standard|open) ;; *) current="standard" ;; esac
  case "$action" in
    status)
      if [ "$JSON" = 1 ]; then
        jq -n --arg posture "$current" \
          --argjson locked "$(_boundary_locked && echo true || echo false)" \
          '{domain:"posture", posture:$posture, locked:$locked}'
      else
        echo "Boundary posture: $current"
        _boundary_locked && echo "(organization boundary policy is locked — posture cannot change)"
      fi
      ;;
    strict|standard|open)
      if _boundary_locked; then
        _die "boundary policy is managed by your organization and locked; posture cannot change" 1
      fi
      if [ "$action" != "$current" ]; then
        _save '.boundary = ((.boundary // {}) + {posture: $p})' --arg p "$action"
      fi
      echo "Boundary posture: $action · applies to new sessions · /save shares it with the org"
      ;;
    *) _die "usage: settings.sh posture status|strict|standard|open" 1 ;;
  esac
}

# ── personal boundary read roots ─────────────────────────────────────────
# Personal-only: edits .egregore-boundary.local.json for the current member.
# Respects org `locked: true` (no personal expansion), and never accepts a
# path inside another Egregore instance — the hard tier has no consent path.

LOCAL_BOUNDARY="$SCRIPT_DIR/.egregore-boundary.local.json"

_boundary_locked() {
  [ "$(jq -r '.boundary.locked // false' "$CONFIG" 2>/dev/null)" = "true" ]
}

_inside_foreign_instance() {
  local target="$1" registry="$HOME/.egregore/instances.json" p self
  [ -f "$registry" ] || return 1
  self=$(cd "$SCRIPT_DIR" 2>/dev/null && pwd -P)
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    p=$(cd "$p" 2>/dev/null && pwd -P) || continue
    [ "$p" = "$self" ] && continue
    case "$target" in "$p"|"$p"/*) return 0 ;; esac
  done < <(jq -r '.[].path // empty' "$registry" 2>/dev/null)
  return 1
}

cmd_boundary() {
  local action="${1:-list}" raw target current
  case "$action" in
    list)
      current=$(jq -c '.read // []' "$LOCAL_BOUNDARY" 2>/dev/null || echo '[]')
      if [ "$JSON" -eq 1 ]; then
        jq -n --argjson read "$current" --argjson locked "$(_boundary_locked && echo true || echo false)" \
          '{personal_read_roots: $read, locked: $locked}'
      else
        echo "personal read roots:"
        printf '%s\n' "$current" | jq -r '.[] // empty' | sed 's/^/  /'
        _boundary_locked && echo "(organization boundary policy is locked — personal changes disabled)"
      fi
      ;;
    add|remove)
      raw="${2:-}"
      [ -n "$raw" ] || _die "usage: settings.sh boundary $action <directory>" 1
      if _boundary_locked; then
        _die "boundary policy is managed by your organization and locked; personal read roots cannot change" 1
      fi
      case "$raw" in "~"*) target="$HOME${raw#\~}" ;; *) target="$raw" ;; esac
      target=$(cd "$target" 2>/dev/null && pwd -P) || {
        [ "$action" = "remove" ] && target="$raw" || _die "directory not found: $raw" 1
      }
      if [ "$action" = "add" ]; then
        if _inside_foreign_instance "$target"; then
          _die "that directory belongs to another Egregore instance; it can never be a personal read root" 1
        fi
        [ -f "$LOCAL_BOUNDARY" ] || printf '{}\n' > "$LOCAL_BOUNDARY"
        tmp="$(mktemp "$LOCAL_BOUNDARY.XXXXXX")"
        if jq --arg p "$target" '.read = ((.read // []) + [$p] | unique)' "$LOCAL_BOUNDARY" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
          mv "$tmp" "$LOCAL_BOUNDARY"
          echo "added personal read root: $target (applies from the next session start)"
        else
          rm -f "$tmp"; _die "failed to update $LOCAL_BOUNDARY" 1
        fi
      else
        [ -f "$LOCAL_BOUNDARY" ] || { echo "removed personal read root: $raw (was not present)"; return 0; }
        tmp="$(mktemp "$LOCAL_BOUNDARY.XXXXXX")"
        if jq --arg p "$target" --arg raw "$raw" '.read = ((.read // []) | map(select(. != $p and . != $raw)))' "$LOCAL_BOUNDARY" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
          mv "$tmp" "$LOCAL_BOUNDARY"
          echo "removed personal read root: $target"
        else
          rm -f "$tmp"; _die "failed to update $LOCAL_BOUNDARY" 1
        fi
      fi
      ;;
    *) _die "usage: settings.sh boundary list|add <dir>|remove <dir>" 1 ;;
  esac
}

DOMAIN="${1:-}"; shift || true
case "$DOMAIN" in
  hosting) cmd_hosting "$@" ;;
  relay)   cmd_relay "$@" ;;
  workflow) cmd_workflow "$@" ;;
  repo)    cmd_repo "$@" ;;
  admin)   cmd_admin "$@" ;;
  people)  cmd_people "$@" ;;
  privacy) cmd_privacy ;;
  posture) cmd_posture "$@" ;;
  push)    _control_plane_push ;;
  boundary) cmd_boundary "$@" ;;
  dump)    cmd_dump ;;
  ""|-h|--help|help) usage 0 ;;
  *) _die "unknown settings domain: '$DOMAIN' (try: hosting, relay, workflow, repo, admin, people, privacy, posture, boundary, dump)" 1 ;;
esac
