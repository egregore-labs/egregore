#!/usr/bin/env bash
set -euo pipefail

# One identity spine for .egregore-state.json, memory/people, Supabase, and
# Neo4j. GitHub's numeric id is the durable key when available.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$ROOT"
CONFIG="$ROOT/egregore.json"
STATE="$ROOT/.egregore-state.json"
PERSON_PY="$ROOT/bin/person.py"

# shellcheck source=bin/lib/config.sh
source "$ROOT/bin/lib/config.sh"

usage() {
  echo 'usage: bash bin/person.sh {sync|onboard|set-name NAME|set-email EMAIL|show|backfill [--dry-run|--apply] [--include-removed]}' >&2
  exit 2
}

remote_config() {
  api_url="${EGREGORE_API_URL:-$(_config_val api_url)}"
  api_key="${EGREGORE_API_KEY:-$(_load_env_var EGREGORE_API_KEY)}"
}

sync_remote_identity() {
  identity="$1"
  remote_config

  api_status="not-configured"
  platform_user_id=""
  if [ -n "$api_url" ] && [ -n "$api_key" ]; then
    api_payload="$(printf '%s' "$identity" | jq '{
      github_username,
      github_id,
      github_name,
      github_aliases,
      display_name,
      email,
      emails
    }')"
    api_result="$(curl -sf "${api_url}/api/user/ensure" \
      -H "Authorization: Bearer ${api_key}" \
      -H "Content-Type: application/json" \
      -d "$api_payload" \
      --max-time 10 2>/dev/null || true)"
    api_status="$(printf '%s' "$api_result" | jq -r '.status // "failed"' 2>/dev/null || echo failed)"
    platform_user_id="$(printf '%s' "$api_result" | jq -r '.user_id // empty' 2>/dev/null || true)"
  fi

  # A removed membership is terminal until an admin explicitly re-invites
  # the person. Never let startup recreate their graph membership.
  if [ "$api_status" = "removed" ]; then
    printf '%s' "$identity" | jq \
      --arg platform_user_id "$platform_user_id" \
      '. + {
        status:"removed",
        supabase:"removed",
        graph:"skipped-removed",
        platform_user_id:$platform_user_id,
        merged_duplicates:0
      }'
    return 0
  fi

  params="$(printf '%s' "$identity" | jq --arg platformUserId "$platform_user_id" '{
    personId:.person_id,
    github:.github_username,
    githubId:(if .github_id == null then "" else (.github_id|tostring) end),
    fullName:.github_name,
    displayName:.display_name,
    primaryEmail:(.email // ""),
    emails,
    githubAliases:.github_aliases,
    previousNames:.previous_names,
    profilePath:.profile_path,
    allowNameMatch:(
      (.allow_name_match // false)
      or (.source_profile // "") != ""
      or ((.aliases_reconciled // []) | length) > 0
    ),
    platformUserId:$platformUserId
  }')"

  graph_status="failed"
  if graph_result="$(bash "$ROOT/bin/graph.sh" query "
    OPTIONAL MATCH (legacy:Person)
    WHERE NOT coalesce(legacy.kind, '') IN ['external', 'identity_alias']
      AND coalesce(legacy.status, 'active') = 'active'
      AND legacy.ingestRef IS NULL
      AND (
        legacy.personId = \$personId
        OR (\$githubId <> '' AND coalesce(toString(legacy.githubId), '') = \$githubId)
        OR toLower(coalesce(legacy.github, '')) = toLower(\$github)
        OR toLower(coalesce(legacy.github, '')) IN
          [alias IN \$githubAliases | toLower(alias)]
        OR (
          \$allowNameMatch
          AND legacy.personId IS NULL
          AND legacy.githubId IS NULL
          AND (legacy.github IS NULL OR legacy.github = '')
          AND toLower(coalesce(legacy.name, '')) = toLower(\$displayName)
        )
      )
    WITH legacy
    ORDER BY CASE
      WHEN legacy.personId = \$personId THEN 0
      WHEN \$githubId <> '' AND coalesce(toString(legacy.githubId), '') = \$githubId THEN 1
      WHEN toLower(coalesce(legacy.github, '')) = toLower(\$github) THEN 2
      ELSE 3
    END
    WITH head(collect(legacy)) AS legacy
    FOREACH (_ IN CASE WHEN legacy IS NULL THEN [] ELSE [1] END |
      SET legacy.personId = \$personId
    )
    MERGE (p:Person {personId: \$personId})
    ON CREATE SET p.joined = date()
    SET p.github = \$github,
        p.githubId = CASE WHEN \$githubId = '' THEN p.githubId ELSE \$githubId END,
        p.kind = 'member',
        p.org = \$_org,
        p.status = 'active',
        p.removedAt = null,
        p.identityStatus = CASE WHEN \$githubId = '' THEN 'provisional' ELSE 'verified' END,
        p.platformUserId = CASE WHEN \$platformUserId = '' THEN p.platformUserId ELSE \$platformUserId END,
        p.name = \$displayName,
        p.displayName = \$displayName,
        p.fullName = \$fullName,
        p.email = CASE WHEN \$primaryEmail = '' THEN p.email ELSE \$primaryEmail END,
        p.emails = reduce(acc = coalesce(p.emails, []), value IN \$emails |
          CASE WHEN value IN acc THEN acc ELSE acc + value END),
        p.githubAliases = reduce(acc = coalesce(p.githubAliases, []), value IN \$githubAliases |
          CASE WHEN value IN acc THEN acc ELSE acc + value END),
        p.previousNames = reduce(acc = coalesce(p.previousNames, []), value IN \$previousNames |
          CASE WHEN value IN acc THEN acc ELSE acc + value END),
        p.profilePath = \$profilePath,
        p.identityVersion = 1,
        p.identityUpdatedAt = datetime()
    WITH p
    MATCH (o:Org {id: \$_org})
    MERGE (p)-[:MEMBER_OF]->(o)
    RETURN p.personId AS personId
  " "$params" 2>/dev/null)"; then
    if printf '%s' "$graph_result" | jq -e \
      --arg personId "$(printf '%s' "$identity" | jq -r .person_id)" \
      '.values[0][0] == $personId' >/dev/null 2>&1; then
      graph_status="synced"
    fi
  fi

  merged_duplicates=0
  if [ "$graph_status" = "synced" ]; then
    duplicates="$(bash "$ROOT/bin/graph.sh" query "
      MATCH (real:Person {personId: \$personId})
      MATCH (duplicate:Person)
      WHERE duplicate <> real AND (
        duplicate.personId = \$personId
        OR (\$githubId <> '' AND coalesce(toString(duplicate.githubId), '') = \$githubId)
        OR toLower(coalesce(duplicate.github, '')) = toLower(\$github)
        OR toLower(coalesce(duplicate.github, '')) IN \$githubAliases
        OR (
          duplicate.githubId IS NULL
          AND duplicate.personId IS NULL
          AND (duplicate.github IS NULL OR duplicate.github = '')
          AND any(email IN coalesce(duplicate.emails, []) WHERE email IN \$emails)
        )
        OR (
          \$allowNameMatch
          AND
          (duplicate.github IS NULL OR duplicate.github = '')
          AND duplicate.personId IS NULL
          AND toLower(coalesce(duplicate.name, '')) = toLower(\$displayName)
        )
      )
      AND NOT coalesce(duplicate.kind, '') IN ['external', 'identity_alias']
      AND coalesce(duplicate.status, 'active') = 'active'
      AND duplicate.ingestRef IS NULL
      RETURN DISTINCT coalesce(duplicate.github, duplicate.name) AS ref
    " "$params" 2>/dev/null || echo '{"values":[]}')"
    while IFS= read -r duplicate; do
      [ -n "$duplicate" ] || continue
      if bash "$ROOT/bin/graph-op.sh" merge-person "$(printf '%s' "$identity" | jq -r .person_id)" \
        "$duplicate" >/dev/null 2>&1; then
        merged_duplicates=$((merged_duplicates + 1))
      fi
    done < <(printf '%s' "$duplicates" | jq -r '.values[]?[0] // empty')
  fi

  status="synced"
  [ "$api_status" = "ok" ] || status="partial"
  [ "$graph_status" = "synced" ] || status="partial"
  printf '%s' "$identity" | jq \
    --arg status "$status" \
    --arg supabase "$api_status" \
    --arg graph "$graph_status" \
    --arg platform_user_id "$platform_user_id" \
    --argjson merged_duplicates "$merged_duplicates" \
    '. + {
      status:$status,
      supabase:$supabase,
      graph:$graph,
      platform_user_id:$platform_user_id,
      merged_duplicates:$merged_duplicates
    }'
}

backfill_people() {
  mode="dry-run"
  include_removed="false"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) mode="dry-run" ;;
      --apply) mode="apply" ;;
      --include-removed) include_removed="true" ;;
      *) usage ;;
    esac
    shift
  done

  if [ "$(_detect_mode)" = "local" ]; then
    jq -n '{status:"unavailable",reason:"person backfill requires the hosted member roster in this configuration"}'
    return 1
  fi
  command -v gh >/dev/null 2>&1 || {
    jq -n '{status:"error",error:"GitHub CLI is required to resolve stable user ids"}'
    return 1
  }

  remote_config
  if [ -z "$api_url" ] || [ -z "$api_key" ]; then
    jq -n '{status:"error",error:"connected API configuration is incomplete"}'
    return 1
  fi
  org_slug="$(_config_val slug)"
  members_result="$(curl -sf "${api_url}/api/org/${org_slug}/members?include_removed=true" \
    -H "Authorization: Bearer ${api_key}" \
    --max-time 20 2>/dev/null || true)"
  if ! printf '%s' "$members_result" | jq -e '.members | type == "array"' >/dev/null 2>&1; then
    jq -n '{status:"error",error:"could not load the hosted member roster"}'
    return 1
  fi
  if ! printf '%s' "$members_result" | jq -e \
    '.members | length == 0 or all(has("github_id") and has("github_aliases"))' \
    >/dev/null 2>&1; then
    jq -n '{status:"blocked",error:"the hosted API is still using the pre-identity member contract; deploy it before backfilling"}'
    return 1
  fi

  results='[]'
  excluded_removed=0
  while IFS= read -r member; do
    [ -n "$member" ] || continue
    member_status="$(printf '%s' "$member" | jq -r '.status // "active"')"
    if [ "$member_status" != "active" ] && [ "$include_removed" != "true" ]; then
      excluded_removed=$((excluded_removed + 1))
      continue
    fi

    previous_github="$(printf '%s' "$member" | jq -r '.github_username // empty')"
    if ! printf '%s' "$previous_github" | grep -Eq '^[A-Za-z0-9-]{1,39}$'; then
      item="$(jq -n --arg github "$previous_github" '{
        github_username:$github,status:"skipped",reason:"invalid GitHub login"
      }')"
      results="$(printf '%s' "$results" | jq --argjson item "$item" '. + [$item]')"
      continue
    fi

    github_result="$(gh api "users/${previous_github}" \
      --jq '{login,id,name,email}' 2>/dev/null || true)"
    if ! printf '%s' "$github_result" | jq -e \
      '.login and (.id | type == "number")' >/dev/null 2>&1; then
      item="$(jq -n --arg github "$previous_github" '{
        github_username:$github,status:"unresolved",reason:"GitHub identity could not be resolved"
      }')"
      results="$(printf '%s' "$results" | jq --argjson item "$item" '. + [$item]')"
      continue
    fi

    github="$(printf '%s' "$github_result" | jq -r .login)"
    github_id="$(printf '%s' "$github_result" | jq -r .id)"
    github_name="$(printf '%s' "$github_result" | jq -r '.name // empty')"
    public_email="$(printf '%s' "$github_result" | jq -r '.email // empty')"
    display_name="$(printf '%s' "$member" | jq -r \
      --arg githubName "$github_name" --arg github "$github" \
      '.display_name // (if $githubName != "" then $githubName else $github end)')"
    role="$(printf '%s' "$member" | jq -r '.member_role // .role // "Member"')"
    joined="$(printf '%s' "$member" | jq -r '.joined_at // empty' | cut -c1-10)"
    aliases="$(printf '%s' "$member" | jq -r \
      --arg old "$previous_github" --arg current "$github" '
      ((.github_aliases // []) + (if ($old|ascii_downcase) != ($current|ascii_downcase) then [$old] else [] end))
      | map(select(type == "string" and length > 0)) | unique | join(",")
    ')"
    emails="$(printf '%s' "$member" | jq -r \
      --arg public "$public_email" '
      ((.emails // []) + [(.primary_email // ""), $public])
      | map(select(type == "string" and length > 0)) | unique | join(",")
    ')"

    profile_args=(
      sync-profile
      --github "$github"
      --github-id "$github_id"
      --github-name "$github_name"
      --display-name "$display_name"
      --previous-github "$previous_github"
      --github-aliases "$aliases"
      --emails "$emails"
      --role "$role"
      --joined "$joined"
    )
    [ "$mode" = "apply" ] || profile_args+=(--dry-run)
    if ! identity="$(python3 "$PERSON_PY" "${profile_args[@]}")"; then
      item="$(jq -n --arg github "$github" '{
        github_username:$github,status:"skipped",reason:"profile reconciliation failed"
      }')"
      results="$(printf '%s' "$results" | jq --argjson item "$item" '. + [$item]')"
      continue
    fi
    roster_name_matches="$(printf '%s' "$members_result" | jq \
      --arg displayName "$display_name" '
      [.members[]
        | (.display_name // "")
        | select(length > 0)
        | ascii_downcase
        | select(. == ($displayName | ascii_downcase))]
      | length
    ')"
    allow_name_match="false"
    [ "$roster_name_matches" -eq 1 ] && allow_name_match="true"
    identity="$(printf '%s' "$identity" | jq \
      --argjson allowNameMatch "$allow_name_match" \
      '.allow_name_match = $allowNameMatch')"

    if [ "$mode" = "apply" ]; then
      synced="$(sync_remote_identity "$identity")"
      report="$(printf '%s' "$synced" | jq 'del(.email,.emails,.allow_name_match)')"
    else
      report="$(printf '%s' "$identity" | jq \
        '. + {status:"planned"} | del(.email,.emails,.allow_name_match)')"
    fi
    results="$(printf '%s' "$results" | jq --argjson item "$report" '. + [$item]')"
  done < <(printf '%s' "$members_result" | jq -c '.members[]')

  printf '%s' "$results" | jq \
    --arg mode "$mode" \
    --arg org "$org_slug" \
    --argjson excluded_removed "$excluded_removed" '
    {
      status:(if any(.[]; .status == "partial") then "partial" else "ok" end),
      mode:$mode,
      org:$org,
      summary:{
        considered:length,
        planned_or_synced:[.[] | select(.status == "planned" or .status == "synced")]|length,
        partial:[.[] | select(.status == "partial")]|length,
        unresolved:[.[] | select(.status == "unresolved")]|length,
        skipped:[.[] | select(.status == "skipped")]|length,
        excluded_removed:$excluded_removed
      },
      people:.
    }'
}

command="${1:-}"
[ -n "$command" ] || usage

if [ "$command" = "show" ]; then
  jq '{
    person_id,
    display_name,
    github_username,
    github_id,
    github_name,
    email,
    emails,
    github_aliases,
    previous_names,
    identity_version
  }' "$STATE"
  exit 0
fi

if [ "$command" = "backfill" ]; then
  backfill_people "$@"
  exit $?
fi

display_args=()
email_args=()
onboard_args=()
case "$command" in
  sync) ;;
  onboard) onboard_args=(--onboarded) ;;
  set-name)
    name="${2:-}"
    [ -n "$name" ] || usage
    if [ "${#name}" -gt 60 ] || ! printf '%s' "$name" | grep -Eq "^[[:alnum:]À-ž .'-]+$"; then
      echo '{"status":"error","error":"display name must be 1-60 name characters"}'
      exit 2
    fi
    display_args=(--display-name "$name")
    ;;
  set-email)
    email="${2:-}"
    [ -n "$email" ] || usage
    if [ "${#email}" -gt 254 ] || ! printf '%s' "$email" | grep -Eq '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'; then
      echo '{"status":"error","error":"email must be a valid address"}'
      exit 2
    fi
    email_args=(--email "$email")
    ;;
  *) usage ;;
esac

github_args=()
state_github="$(jq -r '.github_username // empty' "$STATE" 2>/dev/null)"
if command -v gh >/dev/null 2>&1; then
  gh_identity="$(gh api user --jq '{login,id,name,email}' 2>/dev/null || true)"
  gh_login="$(printf '%s' "$gh_identity" | jq -r '.login // empty' 2>/dev/null)"
  gh_id="$(printf '%s' "$gh_identity" | jq -r '.id // empty' 2>/dev/null)"
  state_github_id="$(jq -r '.github_id // empty' "$STATE" 2>/dev/null)"
  gh_login_lc="$(printf '%s' "$gh_login" | tr '[:upper:]' '[:lower:]')"
  state_github_lc="$(printf '%s' "$state_github" | tr '[:upper:]' '[:lower:]')"
  if [ -n "$gh_login" ] && {
    [ -z "$state_github" ] ||
    [ "$gh_login_lc" = "$state_github_lc" ] ||
    { [ -n "$gh_id" ] && [ -n "$state_github_id" ] && [ "$gh_id" = "$state_github_id" ]; }
  }; then
    github_args=(--github "$gh_login")
    gh_email="$(printf '%s' "$gh_identity" | jq -r '.email // empty')"
    [ -z "$gh_id" ] || github_args+=(--github-id "$gh_id")
    [ -z "$gh_email" ] || github_args+=(--email "$gh_email")
  fi
fi

if [ "$(jq -r '.onboarding_complete // false' "$STATE" 2>/dev/null)" = "true" ]; then
  onboard_args=(--onboarded)
fi
identity="$(python3 "$PERSON_PY" sync-local \
  "${display_args[@]}" "${github_args[@]}" "${email_args[@]}" "${onboard_args[@]}")"

if [ "$(_detect_mode)" = "local" ]; then
  printf '%s' "$identity" | jq '. + {status:"synced-local",supabase:"unavailable",graph:"unavailable"}'
  exit 0
fi

sync_remote_identity "$identity"
