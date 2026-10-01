#!/usr/bin/env bash
set -euo pipefail
# Named operations for the optional hosted index.
# Keeps implementation details out of the TUI.
#
# Usage: bash bin/graph-op.sh <operation> [args...]
#
# Session resolution: use the checkout-path receipt
# ~/.egregore/session-<hash-of-SCRIPT_DIR>.id first, then the shared
# .egregore-session-id file when the receipt has no usable id.
#
# Operations:
#   mark-read <session-id> [user]     Mark a handoff as read
#   mark-done <session-id> [user]     Mark a handoff as done/resolved
#   mark-expired <session-id> [user]  Explicitly expire an open handoff
#   reopen-handoff <session-id> [user] Reopen a terminal handoff
#   answer-question <set-id>    Mark a question set as answered
#   resolve-handoffs <user>     Resolve completed explicit implementation lineage
#   set-topic <session-id> <topic> [branch]
#                               Set topic (and optionally branch) on a Session node
#   set-current-topic <topic> [branch]
#                               set-topic for this session — reads the id from
#                               the checkout receipt or .egregore-session-id,
#                               so callers never need a $(cat …) substitution.
#                               Worktree-isolated Claude Code sessions refuse
#                               that shape.
#   create-pr <session-id> <pr-number> <repo> <author> [title]
#                               Record a PR and link it to its session
#   record-pr <pr-number> [title]
#                               create-pr for this session — resolves the session
#                               id, repository, and author itself
#   record-focus <session-id> <shown-json> <selected> [dismissed-json]
#                               Track Focus option selection for adaptive options
#   merge-person <keep-name> <alias-name>
#                               Reconcile two Person nodes — projects relationships
#                               to keep-name and retains alias-name append-only
#   create-harvest <id> <topic> <intent> <initiator>
#                               Create a Harvest node and link to initiator (WAL-backed)
#   create-harvest-session <harvest-id> <session-id> <person-name> [status]
#                               Create a HarvestSession linked to a Harvest and Person.
#                               status defaults to 'active' (back-compat). Valid values:
#                               pending | active | answered | complete | incorporated.
#                               Async respondents should be created with 'pending'.
#   record-harvest-turn <session-id> <turn> <question> <intent> [answer] [eval]
#                               Record a question-answer turn in a HarvestSession
#   complete-harvest <harvest-id> <artifact-path>
#                               Mark harvest complete and link synthesis artifact
#   catalog                     List bounded read operations and their contracts
#   people                      Read every Person's name and github
#   open-quests                 Read non-closed quests' name, description, status
#   spirit-context              Read active quests, recent sessions, health signals
#   spirit-list                 Read active spirits' name, type, cadence
#   spirit-create --name <name> --type <recurring|watchdog> --purpose <purpose>
#                 --cadence <cadence> --status <active|suspended> --author <author>
#                               Create a Spirit (WAL-backed)
#   spirit-update --name <name> --id <id> --title <title> --metrics <metrics>
#                               Record a spirit's cycle report (WAL-backed)
#   register-emissary --id <id> --topic <topic> --kind <kind> --url <url>
#                     --author <author> --session-id <session-id>
#                               Index an Emissary and its author/session (WAL-backed)
#   register-eval-report --id <id> --title <title> --file-path <path> --author <author>
#                               Index an eval report and its author (WAL-backed)
#   open-handoffs <user> [limit] Read non-terminal handoffs addressed to a person
#   pending-questions <user> [limit] Read active question sets awaiting a person
#   lineage <topic> [limit]     Trace matching sessions, handoffs, implementations,
#                               PRs, and canonical evidence files
#   meeting-history <query> [limit]
#                               Find a meeting sequence, participants, derived
#                               knowledge, and unprojected canonical meeting files

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

resolve_session_id() {
  local project_hash session_id="" receipt
  # Match identity.sh's checkout spelling and hash, before the shared fallback
  # that a later session in another worktree may have overwritten.
  project_hash="$(printf '%s' "$SCRIPT_DIR" | md5 2>/dev/null || printf '%s' "$SCRIPT_DIR" | md5sum 2>/dev/null | cut -d' ' -f1 || true)"
  if [ -n "$project_hash" ] && [ -n "${HOME:-}" ]; then
    receipt="$HOME/.egregore/session-${project_hash}.id"
    if [ -f "$receipt" ]; then
      session_id="$(tr -cd 'A-Za-z0-9_.-' < "$receipt")"
    fi
  fi
  if [ -z "$session_id" ] && [ -f "$SCRIPT_DIR/.egregore-session-id" ]; then
    session_id="$(tr -cd 'A-Za-z0-9_.-' < "$SCRIPT_DIR/.egregore-session-id")"
  fi
  printf '%s' "$session_id"
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  echo "Usage: graph-op.sh <operation> [args...]"
  echo ""
  echo "Named operations for the optional hosted index."
  echo ""
  echo "Operations:"
  echo "  mark-read <sid> [user]       Mark handoff as read"
  echo "  mark-done <sid> [user]       Mark handoff as done"
  echo "  mark-expired <sid> [user]    Explicitly expire an open handoff"
  echo "  reopen-handoff <sid> [user]  Reopen a done/expired handoff"
  echo "  answer-question <qid>    Mark question set as answered"
  echo "  resolve-handoffs <user>  Resolve completed implementation lineage"
  echo "  set-topic <sid> <topic>  Set topic on a Session node"
  echo "  set-current-topic <topic> [branch]  set-topic for this session (resolves checkout session id)"
  echo "  merge-person <keep> <alias> Reconcile a Person as a canonical alias"
  echo "  claim-handoff <sid> <ho> Link implementing session to handoff"
  echo "  create-pr <sid> <num> <repo> <author> [title]"
  echo "  record-pr <pr-number> [title]  create-pr for this session (resolves session, repo, author)"
  echo "  register-artifact <id> <url> <title> <type> <author> <topics> <excerpt>"
  echo "  register-emissary --id <id> --topic <topic> --kind <kind> --url <url> --author <author> --session-id <session-id>"
  echo "  register-eval-report --id <id> --title <title> --file-path <path> --author <author>"
  echo "  spirit-create --name <name> --type <recurring|watchdog> --purpose <purpose> --cadence <cadence> --status <active|suspended> --author <author>"
  echo "  spirit-update --name <name> --id <id> --title <title> --metrics <metrics>  Record a cycle report"
  echo "  create-harvest / complete-harvest / record-harvest-turn"
  echo "  catalog                        List bounded read operation contracts"
  echo "  people                      Read every Person's name and github"
  echo "  open-quests                 Read non-closed quests' name, description, status"
  echo "  spirit-context              Read active quests, recent sessions, health signals"
  echo "  spirit-list                 Read active spirits' name, type, cadence"
  echo "  open-handoffs <user> [n]     Read recent non-terminal handoffs"
  echo "  pending-questions <user> [n] Read recent active question sets"
  echo "  lineage <topic> [n]          Trace handoff/implementation/PR evidence"
  echo "  meeting-history <query> [n] Find meeting continuity and coverage gaps"
  echo "  wal-status               Show WAL pending count"
  exit 0
fi

GS="$SCRIPT_DIR/bin/graph.sh"

# Named reads are explicit projection requests by definition — they pass the
# Runtime cutover gate that silences background graph callers.
export EGREGORE_GRAPH_EXPLICIT=1

OP="${1:-}"
shift || true

# --- Local mode gate: bail immediately ---
# Read the mode explicitly: under set -e a jq failure on a missing config
# used to end the script with exit 2 and no message.
if [ ! -f "$SCRIPT_DIR/egregore.json" ]; then
  echo "graph-op.sh: egregore.json not found at $SCRIPT_DIR — not an Egregore checkout?" >&2
  exit 2
fi
_MODE=$(jq -r '.mode // "connected"' "$SCRIPT_DIR/egregore.json" 2>/dev/null || echo "connected")

# The catalog is static runtime metadata, not a graph read. Keep it available
# in local mode so every harness can route correctly without opening this file
# or guessing whether an operation exists.
if [ "$OP" = "catalog" ]; then
  jq -n --arg mode "$_MODE" '{
    schema: "egregore.graph-operation-catalog/v1",
    definitionVersion: 1,
    mode: $mode,
    operations: [
      {
        name: "open-handoffs",
        intent: "current non-terminal handoffs addressed to a person",
        usage: "bash bin/graph-op.sh open-handoffs <user> [limit]",
        availability: "connected",
        maxResults: 25,
        evidence: "live graph state"
      },
      {
        name: "pending-questions",
        intent: "current active question sets awaiting a person",
        usage: "bash bin/graph-op.sh pending-questions <user> [limit]",
        availability: "connected",
        maxResults: 25,
        evidence: "live graph state"
      },
      {
        name: "lineage",
        intent: "handoff to implementation, branch, PR, and superseding direction",
        usage: "bash bin/graph-op.sh lineage <topic> [limit]",
        availability: "connected",
        maxResults: 15,
        evidence: "graph relationships plus canonical file pointers"
      },
      {
        name: "meeting-history",
        intent: "cross-meeting continuity for a company, person, or topic",
        usage: "bash bin/graph-op.sh meeting-history <query> [limit]",
        availability: "connected",
        maxResults: 15,
        evidence: "projected meeting relationships plus canonical file coverage"
      },
      {
        name: "people",
        intent: "names and GitHub handles for every projected person",
        usage: "bash bin/graph-op.sh people",
        availability: "connected",
        fields: ["name", "github"],
        evidence: "live graph state"
      },
      {
        name: "open-quests",
        intent: "names, descriptions and statuses of non-closed quests",
        usage: "bash bin/graph-op.sh open-quests",
        availability: "connected",
        fields: ["name", "description", "status"],
        evidence: "live graph state"
      },
      {
        name: "spirit-context",
        intent: "active quests, recent sessions and spirit health signals",
        usage: "bash bin/graph-op.sh spirit-context",
        availability: "connected",
        maxResults: 1,
        fields: ["context"],
        evidence: "live graph state"
      },
      {
        name: "spirit-list",
        intent: "names, types and cadences of active spirits",
        usage: "bash bin/graph-op.sh spirit-list",
        availability: "connected",
        fields: ["name", "type", "cadence"],
        evidence: "live graph state"
      }
    ]
  }'
  exit 0
fi

if [ "$_MODE" = "local" ]; then
  echo '{"results":[]}'
  exit 0
fi

# Return a bounded set of exact canonical paths containing a literal query.
# This is intentionally a coverage check around graph results, not a second
# full-text answer corpus: agents still open only the relevant canonical files.
memory_file_candidates() {
  local query="$1"
  local limit="$2"
  shift 2
  local filename_hits=""
  local content_hits=""
  local hits=""

  if command -v rg >/dev/null 2>&1; then
    filename_hits="$(
      rg --files --glob '*.md' --glob '!index.md' "$@" 2>/dev/null \
        | sort \
        | while IFS= read -r path; do
            printf '%s' "$path" | grep -Fqi -- "$query" \
              && printf 'filename\t%s\n' "$path"
          done || true
    )"
    content_hits="$(
      rg -i -l -F --glob '*.md' --glob '!index.md' -- "$query" "$@" 2>/dev/null \
        | sort \
        | while IFS= read -r path; do printf 'content\t%s\n' "$path"; done || true
    )"
  else
    content_hits="$(
      find -L "$@" -type f -name '*.md' -print 2>/dev/null \
        | while IFS= read -r path; do
            [ "$(basename "$path")" = "index.md" ] && continue
            printf '%s' "$path" | grep -Fqi -- "$query" \
              && printf 'filename\t%s\n' "$path"
            grep -Fqi -- "$query" "$path" 2>/dev/null \
              && printf 'content\t%s\n' "$path"
          done || true
    )"
  fi

  hits="$(
    printf '%s\n%s\n' "$filename_hits" "$content_hits" \
      | awk -F '	' 'NF >= 2 && !seen[$2]++' \
      | head -n "$limit"
  )"

  while IFS=$'\t' read -r match_kind path; do
    [ -n "$path" ] || continue
    case "$path" in
      "$SCRIPT_DIR"/memory/*)
        printf 'memory/%s\t%s\n' "${path#"$SCRIPT_DIR"/memory/}" "$match_kind"
        ;;
    esac
  done <<< "$hits" | jq -Rsc '
    split("\n")
    | map(select(length > 0))
    | map(split("\t") | {evidencePath: .[0], matchKind: .[1]})
  '
}

# Reduce natural-language read queries to a small set of discriminative terms.
# Named reads should tolerate "42CAP Moritz partner call" without requiring that
# exact phrase to exist in a graph property or canonical Markdown file.
meaningful_query_terms() {
  jq -Rn --arg query "$1" '
    [
      $query
      | ascii_downcase
      | scan("[a-z0-9][a-z0-9._+-]*")
      | select(length >= 3)
      | select(. as $term |
          [
            "about","across","after","before","between","call","calls",
            "company","conversation","evolved","first","from","history",
            "later","meeting","meetings","month","partner","partners",
            "person","the","topic","transcript","transcripts","what","with"
          ]
          | index($term) == null
        )
    ]
    | unique
    | if length == 0 then [$query | ascii_downcase] else .[0:8] end
  '
}

# Build a bounded union of literal coverage checks for each meaningful term.
# The result remains a list of exact canonical paths, not a second answer corpus.
memory_file_candidates_for_terms() {
  local terms_json="$1"
  local limit="$2"
  shift 2
  local combined='[]'
  local term=""
  local term_hits=""

  while IFS= read -r term; do
    [ -n "$term" ] || continue
    term_hits="$(memory_file_candidates "$term" "$limit" "$@")"
    combined="$(
      jq -n \
        --argjson prior "$combined" \
        --argjson next "$term_hits" \
        --argjson limit "$limit" '
          ($prior + $next)
          | unique_by(.evidencePath)
          | .[0:$limit]
        '
    )"
  done < <(printf '%s' "$terms_json" | jq -r '.[]')

  printf '%s\n' "$combined"
}

named_usage_error() {
  echo "$OP: $1" >&2
  echo "Usage: graph-op.sh $OP $NAMED_USAGE" >&2
  exit 2
}

# New flag-based writes share strict field parsing. Values remain data in the
# parameter object; no caller-provided text is interpolated into Cypher.
parse_named_fields() {
  local expected="$1" allow_empty="$2" field value
  shift 2
  NAMED_PARAMS='{}'
  while [ "$#" -gt 0 ]; do
    field="$1"
    case " $expected " in
      *" $field "*) ;;
      *) named_usage_error "unknown argument: $field" ;;
    esac
    [ "$#" -ge 2 ] || named_usage_error "missing value for $field"
    value="$2"
    if [ -z "$value" ]; then
      case " $allow_empty " in
        *" $field "*) ;;
        *) named_usage_error "empty value for $field" ;;
      esac
    fi
    case "$value" in --*) named_usage_error "missing value for $field" ;; esac
    if jq -e --arg field "${field#--}" 'has($field)' <<< "$NAMED_PARAMS" >/dev/null; then
      named_usage_error "duplicate argument: $field"
    fi
    NAMED_PARAMS="$(jq -c --arg field "${field#--}" --arg value "$value" '. + {($field): $value}' <<< "$NAMED_PARAMS")"
    shift 2
  done
  for field in $expected; do
    jq -e --arg field "${field#--}" 'has($field)' <<< "$NAMED_PARAMS" >/dev/null \
      || named_usage_error "missing required argument: $field"
  done
}

case "$OP" in

  people)
    NAMED_USAGE=""
    [ "$#" -eq 0 ] || named_usage_error "this read takes no arguments"
    bash "$GS" query "
      MATCH (p:Person)
      RETURN p.name AS name, p.github AS github
      ORDER BY name, github
    " '{}'
    ;;

  open-quests)
    NAMED_USAGE=""
    [ "$#" -eq 0 ] || named_usage_error "this read takes no arguments"
    bash "$GS" query "
      MATCH (q:Quest)
      WHERE q.status <> 'closed'
      RETURN q.name AS name, q.description AS description, q.status AS status
      ORDER BY name
    " '{}'
    ;;

  spirit-context)
    NAMED_USAGE=""
    [ "$#" -eq 0 ] || named_usage_error "this read takes no arguments"
    bash "$GS" query "
      CALL {
        MATCH (q:Quest)
        WHERE q.status IN ['active', 'in-progress']
        WITH q ORDER BY q.id LIMIT 10
        RETURN collect({id: q.id, title: q.title}) AS activeQuests
      }
      CALL {
        MATCH (s:Session)-[:BY]->(p:Person)
        WITH s, p ORDER BY s.date DESC, s.id, p.name LIMIT 5
        RETURN collect({topic: s.topic, name: p.name, date: toString(s.date)}) AS recentSessions
      }
      CALL {
        MATCH (sp:Spirit)
        WITH sp ORDER BY sp.name LIMIT 10
        RETURN collect({name: sp.name, type: sp.type, status: sp.status}) AS healthSignals
      }
      RETURN {activeQuests: activeQuests, recentSessions: recentSessions,
              healthSignals: healthSignals} AS context
    " '{}'
    ;;

  spirit-list)
    NAMED_USAGE=""
    [ "$#" -eq 0 ] || named_usage_error "this read takes no arguments"
    bash "$GS" query "
      MATCH (sp:Spirit {status: 'active'})
      RETURN sp.name AS name, sp.type AS type, sp.cadence AS cadence
      ORDER BY name
    " '{}'
    ;;

  spirit-create)
    NAMED_USAGE="--name <name> --type <recurring|watchdog> --purpose <purpose> --cadence <cadence> --status <active|suspended> --author <author>"
    parse_named_fields "--name --type --purpose --cadence --status --author" "" "$@"
    jq -e '.type == "recurring" or .type == "watchdog"' <<< "$NAMED_PARAMS" >/dev/null \
      || named_usage_error "type must be recurring or watchdog"
    jq -e '.status == "active" or .status == "suspended"' <<< "$NAMED_PARAMS" >/dev/null \
      || named_usage_error "status must be active or suspended"
    CYPHER="
      MERGE (sp:Spirit {name: \$name})
      SET sp.type = \$type, sp.purpose = \$purpose, sp.cadence = \$cadence,
          sp.status = \$status, sp.createdAt = datetime(), sp.createdBy = \$author,
          sp.version = 1
      RETURN sp.name AS name
    "
    bash "$SCRIPT_DIR/bin/graph-wal.sh" append "$CYPHER" "$NAMED_PARAMS" 2>/dev/null || true
    bash "$GS" query "$CYPHER" "$NAMED_PARAMS"
    ;;

  spirit-update)
    # The cycle update records the report; it does not mutate Spirit settings.
    NAMED_USAGE="--name <name> --id <id> --title <title> --metrics <metrics>"
    parse_named_fields "--name --id --title --metrics" "" "$@"
    CYPHER="
      MATCH (sp:Spirit {name: \$name})
      MERGE (lr:Artifact {id: \$id})
      ON CREATE SET lr.type = 'loop-report', lr.title = \$title,
          lr.created = date(), lr.origin = 'spirit', lr.metrics = \$metrics
      MERGE (lr)-[:GENERATED_BY]->(sp)
      RETURN lr.id AS id
    "
    bash "$SCRIPT_DIR/bin/graph-wal.sh" append "$CYPHER" "$NAMED_PARAMS" 2>/dev/null || true
    bash "$GS" query "$CYPHER" "$NAMED_PARAMS"
    ;;

  register-emissary)
    NAMED_USAGE="--id <id> --topic <topic> --kind <kind> --url <url> --author <author> --session-id <session-id>"
    parse_named_fields "--id --topic --kind --url --author --session-id" "--session-id" "$@"
    jq -e '.url | test("^https?://[^/[:space:]]+")' <<< "$NAMED_PARAMS" >/dev/null \
      || named_usage_error "url must be an http or https URL"
    PARAMS="$(jq -c '{emissaryId: .id, topic, kind, url, author, sessionId: .["session-id"]}' <<< "$NAMED_PARAMS")"
    CYPHER="
      MERGE (e:Emissary {id: \$emissaryId})
      ON CREATE SET e.created = datetime(), e.topic = \$topic, e.kind = \$kind, e.url = \$url
      WITH e
      MATCH (p:Person {github: \$author})
      MERGE (p)-[:SENT_EMISSARY]->(e)
      WITH e
      OPTIONAL MATCH (s:Session {id: \$sessionId})
      WHERE \$sessionId <> ''
      FOREACH (_ IN CASE WHEN s IS NOT NULL THEN [1] ELSE [] END |
        MERGE (s)-[:PRODUCED]->(e))
      RETURN e.id AS id
    "
    bash "$SCRIPT_DIR/bin/graph-wal.sh" append "$CYPHER" "$PARAMS" 2>/dev/null || true
    bash "$GS" query "$CYPHER" "$PARAMS"
    ;;

  register-eval-report)
    NAMED_USAGE="--id <id> --title <title> --file-path <path> --author <author>"
    parse_named_fields "--id --title --file-path --author" "" "$@"
    jq -e '.["file-path"] | (startswith("/") | not) and (split("/") | index("..") | not)' <<< "$NAMED_PARAMS" >/dev/null \
      || named_usage_error "file-path must be a relative path without parent traversal"
    PARAMS="$(jq -c '{id, title, filePath: .["file-path"], author}' <<< "$NAMED_PARAMS")"
    CYPHER="
      MERGE (a:Artifact {id: \$id})
      SET a.title = \$title, a.type = 'eval-report', a.filePath = \$filePath,
          a.created = datetime()
      WITH a
      OPTIONAL MATCH (p:Person {name: \$author})
      FOREACH (_ IN CASE WHEN p IS NOT NULL THEN [1] ELSE [] END |
        MERGE (a)-[:CONTRIBUTED_BY]->(p))
      RETURN a.id AS id
    "
    bash "$SCRIPT_DIR/bin/graph-wal.sh" append "$CYPHER" "$PARAMS" 2>/dev/null || true
    bash "$GS" query "$CYPHER" "$PARAMS"
    ;;

  mark-read)
    SID="${1:?missing session-id}"
    USER="${2:-}"
    bash "$GS" query "
      MATCH (s:Session {id: \$sid})
      OPTIONAL MATCH (s)-[:HANDED_TO]->(recipient:Person)
      WITH s, collect(DISTINCT recipient) AS recipients
      WHERE (\$user = '' OR any(p IN recipients WHERE
        toLower(p.name) = toLower(\$user)
        OR toLower(coalesce(p.github, '')) = toLower(\$user)))
        AND coalesce(s.handoffStatus, 'pending') IN ['pending','read']
      SET s.handoffReadDate = coalesce(s.handoffReadDate, date()),
          s.handoffUpdatedAt = datetime(),
          s.handoffLifecycleVersion = 1
      FOREACH (_ IN CASE WHEN s.handoffIntent = 'fyi' THEN [1] ELSE [] END |
        SET s.handoffStatus = 'done',
            s.handoffDoneAt = coalesce(s.handoffDoneAt, datetime()),
            s.handoffLifecycleReason = 'fyi_read')
      FOREACH (_ IN CASE WHEN coalesce(s.handoffIntent, 'unclassified') <> 'fyi' THEN [1] ELSE [] END |
        SET s.handoffStatus = 'read',
            s.handoffLifecycleReason = 'recipient_read')
      RETURN s.id AS id, s.topic AS topic, s.handoffStatus AS status,
             coalesce(s.handoffIntent, 'unclassified') AS intent
    " "$(jq -n --arg sid "$SID" --arg user "$USER" '{sid: $sid,user: $user}')"
    ;;

  mark-done)
    SID="${1:?missing session-id}"
    USER="${2:-}"
    bash "$GS" query "
      MATCH (s:Session {id: \$sid})
      OPTIONAL MATCH (s)-[:HANDED_TO]->(recipient:Person)
      WITH s, collect(DISTINCT recipient) AS recipients
      WHERE (\$user = '' OR any(p IN recipients WHERE
        toLower(p.name) = toLower(\$user)
        OR toLower(coalesce(p.github, '')) = toLower(\$user)))
        AND coalesce(s.handoffStatus, 'pending') IN ['pending','read','claimed']
      SET s.handoffStatus = 'done',
          s.handoffDoneAt = datetime(),
          s.handoffUpdatedAt = datetime(),
          s.handoffLifecycleReason = 'explicit_done',
          s.handoffLifecycleVersion = 1
      RETURN s.id AS id, s.topic AS topic, s.handoffStatus AS status
    " "$(jq -n --arg sid "$SID" --arg user "$USER" '{sid: $sid,user: $user}')"
    ;;

  mark-expired)
    SID="${1:?missing session-id}"
    USER="${2:-}"
    bash "$GS" query "
      MATCH (s:Session {id: \$sid})
      OPTIONAL MATCH (s)-[:HANDED_TO]->(recipient:Person)
      WITH s, collect(DISTINCT recipient) AS recipients
      WHERE (\$user = '' OR any(p IN recipients WHERE
        toLower(p.name) = toLower(\$user)
        OR toLower(coalesce(p.github, '')) = toLower(\$user)))
        AND coalesce(s.handoffStatus, 'pending') IN ['pending','read','claimed']
      SET s.handoffStatus = 'expired',
          s.handoffExpiredAt = datetime(),
          s.handoffUpdatedAt = datetime(),
          s.handoffLifecycleReason = 'explicit_expired',
          s.handoffLifecycleVersion = 1
      RETURN s.id AS id, s.topic AS topic, s.handoffStatus AS status
    " "$(jq -n --arg sid "$SID" --arg user "$USER" '{sid: $sid,user: $user}')"
    ;;

  reopen-handoff)
    SID="${1:?missing session-id}"
    USER="${2:-}"
    bash "$GS" query "
      MATCH (s:Session {id: \$sid})
      OPTIONAL MATCH (s)-[:HANDED_TO]->(recipient:Person)
      WITH s, collect(DISTINCT recipient) AS recipients
      WHERE (\$user = '' OR any(p IN recipients WHERE
        toLower(p.name) = toLower(\$user)
        OR toLower(coalesce(p.github, '')) = toLower(\$user)))
        AND s.handoffStatus IN ['done','expired','completed']
      SET s.handoffLastDoneAt = s.handoffDoneAt,
          s.handoffLastExpiredAt = s.handoffExpiredAt,
          s.handoffDoneAt = null,
          s.handoffExpiredAt = null,
          s.handoffStatus = 'pending',
          s.handoffReopenedAt = datetime(),
          s.handoffUpdatedAt = datetime(),
          s.handoffLifecycleReason = 'explicit_reopened',
          s.handoffLifecycleVersion = 1
      RETURN s.id AS id, s.topic AS topic, s.handoffStatus AS status
    " "$(jq -n --arg sid "$SID" --arg user "$USER" '{sid: $sid,user: $user}')"
    ;;

  answer-question)
    QID="${1:?missing question-set-id}"
    bash "$GS" query "
      MATCH (qs:QuestionSet {id: \$qid})
      SET qs.status = 'answered'
      RETURN qs.id AS id, qs.topic AS topic
    " "$(jq -n --arg qid "$QID" '{qid: $qid}')"
    ;;

  resolve-handoffs)
    USER="${1:?missing username}"
    bash "$GS" query "
      MATCH (s:Session)-[:HANDED_TO]->(p:Person {name: \$user})
      WHERE s.handoffStatus IN ['read','claimed']
      WITH DISTINCT s, p, size([(s)-[:HANDED_TO]->(:Person) | 1]) AS recipientCount
      WHERE recipientCount = 1
      MATCH (implementation:Session)-[:IMPLEMENTS]->(s)
      MATCH (implementation)-[:BY]->(p)
      WHERE implementation.wrappedAt IS NOT NULL
         OR implementation.status IN ['completed','handed_off','wrapped']
      WITH DISTINCT s, implementation
      SET s.handoffStatus = 'done',
          s.handoffDoneAt = coalesce(s.handoffDoneAt, datetime()),
          s.handoffUpdatedAt = datetime(),
          s.handoffLifecycleReason = 'single_recipient_implemented',
          s.handoffLifecycleVersion = 1
      RETURN s.id AS resolved, implementation.id AS implementation
    " "$(jq -n --arg user "$USER" '{user: $user}')"
    ;;

  set-topic)
    SID="${1:?missing session-id}"
    TOPIC="${2:?missing topic}"
    BRANCH="${3:-}"
    if [ -n "$BRANCH" ]; then
      bash "$GS" query "
        MATCH (s:Session {id: \$sid})
        SET s.topic = \$topic, s.branch = \$branch
        RETURN s.id AS id, s.topic AS topic, s.branch AS branch
      " "$(jq -n --arg sid "$SID" --arg topic "$TOPIC" --arg branch "$BRANCH" '{sid: $sid, topic: $topic, branch: $branch}')"
    else
      bash "$GS" query "
        MATCH (s:Session {id: \$sid})
        SET s.topic = \$topic
        RETURN s.id AS id, s.topic AS topic
      " "$(jq -n --arg sid "$SID" --arg topic "$TOPIC" '{sid: $sid, topic: $topic}')"
    fi
    ;;

  set-current-topic)
    # Same write as set-topic, preferring this checkout's session receipt.
    # No session id (launcher-less shell) is a no-op.
    TOPIC="${1:?missing topic}"
    BRANCH="${2:-}"
    SID="$(resolve_session_id)"
    if [ -z "$SID" ]; then
      echo "set-current-topic: no .egregore-session-id — nothing to update" >&2
      exit 0
    fi
    exec bash "$0" set-topic "$SID" "$TOPIC" "$BRANCH"
    ;;

  record-focus)
    SID="${1:?missing session-id}"
    SHOWN="${2:?missing shown options}"
    SELECTED="${3:?missing selected option}"
    DISMISSED="${4:-[]}"
    bash "$GS" query "
      MATCH (s:Session {id: \$sid})
      SET s.focusShown = \$shown,
          s.focusSelected = \$selected,
          s.focusDismissed = \$dismissed
      RETURN s.id AS id
    " "$(jq -n --arg sid "$SID" --argjson shown "$SHOWN" --arg selected "$SELECTED" --argjson dismissed "$DISMISSED" '{sid: $sid, shown: $shown, selected: $selected, dismissed: $dismissed}')"
    ;;

  merge-person)
    KEEP="${1:?missing keep-name (the Person to keep)}"
    ALIAS="${2:?missing alias-name (the Person to reconcile)}"
    bash "$GS" query "
      MATCH (keep:Person) WHERE (toLower(keep.name) = toLower(\$keep) OR toLower(keep.github) = toLower(\$keep) OR keep.personId = \$keep OR toLower(\$keep) IN [x IN coalesce(keep.githubAliases, []) | toLower(x)] OR toLower(\$keep) IN [x IN coalesce(keep.emails, []) | toLower(x)])
        AND NOT coalesce(keep.kind, '') IN ['external', 'identity_alias']
        AND coalesce(keep.status, 'active') = 'active' AND keep.ingestRef IS NULL
      MATCH (alias:Person) WHERE (toLower(alias.name) = toLower(\$alias) OR toLower(alias.github) = toLower(\$alias) OR alias.personId = \$alias OR toLower(\$alias) IN [x IN coalesce(alias.githubAliases, []) | toLower(x)] OR toLower(\$alias) IN [x IN coalesce(alias.emails, []) | toLower(x)])
        AND NOT coalesce(alias.kind, '') IN ['external', 'identity_alias']
        AND coalesce(alias.status, 'active') = 'active' AND alias.ingestRef IS NULL
      WITH keep, alias WHERE keep <> alias
        AND (
          keep.githubId IS NULL OR alias.githubId IS NULL
          OR toString(keep.githubId) = toString(alias.githubId)
        )
        AND NOT (
          coalesce(keep.personId, '') STARTS WITH 'github:'
          AND coalesce(alias.personId, '') STARTS WITH 'github:'
          AND keep.personId <> alias.personId
        )
      SET keep.previousNames = reduce(
            acc = coalesce(keep.previousNames, []),
            value IN coalesce(alias.previousNames, []) + [alias.name, alias.displayName] |
            CASE WHEN value IS NULL OR toLower(value) = toLower(keep.name) OR value IN acc
              THEN acc ELSE acc + value END
          ),
          keep.githubAliases = reduce(
            acc = coalesce(keep.githubAliases, []),
            value IN coalesce(alias.githubAliases, []) + [alias.github] |
            CASE WHEN value IS NULL OR toLower(value) = toLower(keep.github) OR value IN acc
              THEN acc ELSE acc + value END
          ),
          keep.emails = reduce(
            acc = coalesce(keep.emails, []),
            value IN coalesce(alias.emails, []) + [alias.email] |
            CASE WHEN value IS NULL OR value IN acc THEN acc ELSE acc + value END
          ),
          keep.joined = coalesce(alias.joined, keep.joined),
          keep.invited = coalesce(keep.invited, alias.invited),
          keep.invitedBy = coalesce(keep.invitedBy, alias.invitedBy),
          keep.role = coalesce(keep.role, alias.role),
          keep.domain = coalesce(keep.domain, alias.domain),
          keep.focus = coalesce(keep.focus, alias.focus),
          keep.workStyle = coalesce(keep.workStyle, alias.workStyle),
          keep.telegramId = coalesce(keep.telegramId, alias.telegramId),
          keep.lastBrief = coalesce(keep.lastBrief, alias.lastBrief),
          keep.lastBriefDate = coalesce(keep.lastBriefDate, alias.lastBriefDate),
          keep.lastRecommendations = coalesce(keep.lastRecommendations, alias.lastRecommendations)
      WITH keep, alias
      OPTIONAL MATCH (s1:Session)-[:BY]->(alias)
      FOREACH (_ IN CASE WHEN s1 IS NOT NULL THEN [1] ELSE [] END | MERGE (s1)-[:BY]->(keep))
      WITH keep, alias
      OPTIONAL MATCH (s2:Session)-[:HANDED_TO]->(alias)
      FOREACH (_ IN CASE WHEN s2 IS NOT NULL THEN [1] ELSE [] END | MERGE (s2)-[:HANDED_TO]->(keep))
      WITH keep, alias
      OPTIONAL MATCH (m:Meeting)-[:INVOLVES]->(alias)
      FOREACH (_ IN CASE WHEN m IS NOT NULL THEN [1] ELSE [] END | MERGE (m)-[:INVOLVES]->(keep))
      WITH keep, alias
      OPTIONAL MATCH (a:Artifact)-[:CONTRIBUTED_BY]->(alias)
      FOREACH (_ IN CASE WHEN a IS NOT NULL THEN [1] ELSE [] END | MERGE (a)-[:CONTRIBUTED_BY]->(keep))
      WITH keep, alias
      OPTIONAL MATCH (i:Interview)-[:CONDUCTED_BY]->(alias)
      FOREACH (_ IN CASE WHEN i IS NOT NULL THEN [1] ELSE [] END | MERGE (i)-[:CONDUCTED_BY]->(keep))
      WITH keep, alias
      OPTIONAL MATCH (t:Todo)-[:BY]->(alias)
      FOREACH (_ IN CASE WHEN t IS NOT NULL THEN [1] ELSE [] END | MERGE (t)-[:BY]->(keep))
      WITH keep, alias
      OPTIONAL MATCH (mentionedArtifact:Artifact)-[:MENTIONS]->(alias)
      FOREACH (_ IN CASE WHEN mentionedArtifact IS NOT NULL THEN [1] ELSE [] END | MERGE (mentionedArtifact)-[:MENTIONS]->(keep))
      WITH keep, alias
      OPTIONAL MATCH (mentionedTodo:Todo)-[:MENTIONS]->(alias)
      FOREACH (_ IN CASE WHEN mentionedTodo IS NOT NULL THEN [1] ELSE [] END | MERGE (mentionedTodo)-[:MENTIONS]->(keep))
      WITH keep, alias
      OPTIONAL MATCH (q:Quest)-[:STARTED_BY]->(alias)
      FOREACH (_ IN CASE WHEN q IS NOT NULL THEN [1] ELSE [] END | MERGE (q)-[:STARTED_BY]->(keep))
      WITH keep, alias
      OPTIONAL MATCH (askedBy:QuestionSet)-[:ASKED_BY]->(alias)
      FOREACH (_ IN CASE WHEN askedBy IS NOT NULL THEN [1] ELSE [] END | MERGE (askedBy)-[:ASKED_BY]->(keep))
      WITH keep, alias
      OPTIONAL MATCH (askedTo:QuestionSet)-[:ASKED_TO]->(alias)
      FOREACH (_ IN CASE WHEN askedTo IS NOT NULL THEN [1] ELSE [] END | MERGE (askedTo)-[:ASKED_TO]->(keep))
      WITH keep, alias
      OPTIONAL MATCH (tu:TelegramUser)-[:IDENTIFIES]->(alias)
      FOREACH (_ IN CASE WHEN tu IS NOT NULL THEN [1] ELSE [] END | MERGE (tu)-[:IDENTIFIES]->(keep))
      WITH keep, alias
      OPTIONAL MATCH (reported:Issue)-[:REPORTED_BY]->(alias)
      FOREACH (_ IN CASE WHEN reported IS NOT NULL THEN [1] ELSE [] END | MERGE (reported)-[:REPORTED_BY]->(keep))
      WITH keep, alias
      OPTIONAL MATCH (initiated:Harvest)-[:INITIATED_BY]->(alias)
      FOREACH (_ IN CASE WHEN initiated IS NOT NULL THEN [1] ELSE [] END | MERGE (initiated)-[:INITIATED_BY]->(keep))
      WITH keep, alias
      OPTIONAL MATCH (withPerson:HarvestSession)-[:WITH]->(alias)
      FOREACH (_ IN CASE WHEN withPerson IS NOT NULL THEN [1] ELSE [] END | MERGE (withPerson)-[:WITH]->(keep))
      WITH keep, alias
      OPTIONAL MATCH (alias)-[:SENT_EMISSARY]->(emissary:Emissary)
      FOREACH (_ IN CASE WHEN emissary IS NOT NULL THEN [1] ELSE [] END | MERGE (keep)-[:SENT_EMISSARY]->(emissary))
      WITH keep, alias
      OPTIONAL MATCH (alias)-[:MEMBER_OF]->(o:Org)
      FOREACH (_ IN CASE WHEN o IS NOT NULL THEN [1] ELSE [] END | MERGE (keep)-[:MEMBER_OF]->(o))
      WITH keep, alias
      MERGE (alias)-[:ALIAS_OF]->(keep)
      SET alias.kind = 'identity_alias',
          alias.canonicalPersonId = keep.personId,
          alias.identityStatus = 'alias'
      RETURN keep.name AS name, keep.github AS github, keep.previousNames AS aliases
    " "$(jq -n --arg keep "$KEEP" --arg alias "$ALIAS" '{keep: $keep, alias: $alias}')"
    ;;

  claim-handoff)
    IMPL_SID="${1:?missing implementing-session-id}"
    HO_SID="${2:?missing handoff-session-id}"
    CYPHER="
      MATCH (impl:Session {id: \$implSid}), (ho:Session {id: \$hoSid})
      MATCH (impl)-[:BY]->(claimant:Person)
      MATCH (ho)-[:HANDED_TO]->(claimant)
      WHERE ho.handoffStatus IN ['pending','read','claimed']
      MERGE (impl)-[:IMPLEMENTS]->(ho)
      WITH impl, ho, size([(ho)-[:HANDED_TO]->(:Person) | 1]) AS recipientCount
      FOREACH (_ IN CASE WHEN recipientCount = 1 THEN [1] ELSE [] END |
        SET ho.handoffStatus = 'claimed',
            ho.handoffClaimedAt = coalesce(ho.handoffClaimedAt, datetime()),
            ho.handoffUpdatedAt = datetime(),
            ho.handoffLifecycleReason = 'implementation_claimed',
            ho.handoffLifecycleVersion = 1)
      RETURN impl.id AS implementor, ho.id AS handoff, ho.topic AS topic,
             ho.handoffStatus AS status, recipientCount
    "
    PARAMS="$(jq -n --arg implSid "$IMPL_SID" --arg hoSid "$HO_SID" '{implSid: $implSid, hoSid: $hoSid}')"
    bash "$SCRIPT_DIR/bin/graph-wal.sh" append "$CYPHER" "$PARAMS" 2>/dev/null || true
    bash "$GS" query "$CYPHER" "$PARAMS"
    ;;

  claim-handoff-nudge)
    SID="${1:?missing handoff-session-id}"
    bash "$GS" query "
      MATCH (s:Session {id: \$sid})-[:HANDED_TO]->(recipient:Person)
      WHERE coalesce(s.handoffStatus, 'pending') IN ['pending','read','claimed']
        AND coalesce(s.handoffLifecycleVersion, 0) >= 1
        AND coalesce(s.handoffIntent, 'unclassified') IN ['action','feedback','fyi']
        AND s.handoffNudgedAt IS NULL
        AND (s.handoffNudgeClaimedAt IS NULL
             OR s.handoffNudgeClaimedAt < datetime() - duration('PT1H'))
      WITH s, collect(DISTINCT recipient.name) AS recipients
      WHERE size(recipients) = 1
      SET s.handoffNudgeClaimedAt = datetime(),
          s.handoffNudgeStatus = 'claimed'
      RETURN s.id AS id, s.topic AS topic, recipients
    " "$(jq -n --arg sid "$SID" '{sid:$sid}')"
    ;;

  mark-handoff-nudged)
    SID="${1:?missing handoff-session-id}"
    bash "$GS" query "
      MATCH (s:Session {id: \$sid})
      WHERE s.handoffNudgeStatus = 'claimed' AND s.handoffNudgedAt IS NULL
      SET s.handoffNudgedAt = datetime(),
          s.handoffNudgeStatus = 'sent',
          s.handoffUpdatedAt = datetime(),
          s.handoffLifecycleReason = 'recipient_nudged',
          s.handoffLifecycleVersion = 1
      RETURN s.id AS id, s.handoffNudgeStatus AS status
    " "$(jq -n --arg sid "$SID" '{sid:$sid}')"
    ;;

  release-handoff-nudge)
    SID="${1:?missing handoff-session-id}"
    bash "$GS" query "
      MATCH (s:Session {id: \$sid})
      WHERE s.handoffNudgeStatus = 'claimed' AND s.handoffNudgedAt IS NULL
      SET s.handoffNudgeClaimedAt = null,
          s.handoffNudgeStatus = 'failed',
          s.handoffNudgeFailedAt = datetime()
      RETURN s.id AS id, s.handoffNudgeStatus AS status
    " "$(jq -n --arg sid "$SID" '{sid:$sid}')"
    ;;

  record-pr)
    PR_NUM="${1:-}"
    TITLE="${2:-}"
    if [[ ! "$PR_NUM" =~ ^[0-9]+$ ]]; then
      echo "record-pr: pr-number must be numeric" >&2
      exit 2
    fi
    SID="$(resolve_session_id)"
    if [ -z "$SID" ]; then
      echo "record-pr: no .egregore-session-id — nothing to record" >&2
      exit 0
    fi
    REPO="$(jq -r '.repo_name // "egregore"' "$SCRIPT_DIR/egregore.json" 2>/dev/null || printf '%s' 'egregore')"
    AUTHOR="$(jq -r '.github_username // empty' "$SCRIPT_DIR/.egregore-state.json" 2>/dev/null || true)"
    exec bash "$0" create-pr "$SID" "$PR_NUM" "$REPO" "$AUTHOR" "$TITLE"
    ;;

  create-pr)
    SID="${1:?missing session-id}"
    PR_NUM="${2:?missing pr-number}"
    REPO="${3:?missing repo}"
    AUTHOR_GH="${4?missing author-github}"
    TITLE="${5:-}"
    CYPHER="
      MERGE (pr:PR {number: toInteger(\$num), repo: \$repo})
      ON CREATE SET pr.author = \$author, pr.status = 'open',
        pr.createdAt = datetime(), pr.title = \$title
      WITH pr
      OPTIONAL MATCH (s:Session {id: \$sid})
      FOREACH (_ IN CASE WHEN s IS NOT NULL THEN [1] ELSE [] END |
        MERGE (s)-[:PRODUCED]->(pr))
      RETURN pr.number AS number, pr.repo AS repo
    "
    PARAMS="$(jq -n --arg sid "$SID" --argjson num "$PR_NUM" --arg repo "$REPO" --arg author "$AUTHOR_GH" --arg title "$TITLE" '{sid: $sid, num: $num, repo: $repo, author: $author, title: $title}')"
    bash "$SCRIPT_DIR/bin/graph-wal.sh" append "$CYPHER" "$PARAMS" 2>/dev/null || true
    bash "$GS" query "$CYPHER" "$PARAMS"
    ;;

  register-artifact)
    # Index a published (hosted) artifact as an Artifact node so the finder can
    # retrieve it from the graph in connected mode — by content (title/topics/
    # excerpt CONTAINS) and by relationship (who made it, which quest). The node
    # id is the registry FILENAME STEM (date-author-slug), matching sync-graph.sh
    # so a later /save sync upserts the same node instead of duplicating it.
    # args: <id> <url> <title> <type> <author-handle> <topics-csv> <excerpt>
    A_ID="${1:?missing id}"
    A_URL="${2:?missing url}"
    A_TITLE="${3:-}"
    A_TYPE="${4:-artifact}"
    A_AUTHOR="$(printf '%s' "${5:-}" | tr '[:upper:]' '[:lower:]' | awk '{print $1}')"
    A_TOPICS_JSON="$(printf '%s' "${6:-}" | jq -Rc 'split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length > 0))' 2>/dev/null || echo '[]')"
    A_EXCERPT="$(printf '%s' "${7:-}" | tr '\n' ' ' | cut -c1-2000)"
    CYPHER="
      MERGE (a:Artifact {id: \$id})
      ON CREATE SET a.created = datetime()
      SET a.title = \$title, a.type = \$type, a.url = \$url,
          a.topics = \$topics, a.excerpt = \$excerpt, a.published = true
      WITH a
      OPTIONAL MATCH (p:Person)
        WHERE \$author <> '' AND (toLower(p.name) = \$author OR p.github = \$author)
      FOREACH (_ IN CASE WHEN p IS NOT NULL THEN [1] ELSE [] END |
        MERGE (a)-[:CONTRIBUTED_BY]->(p))
      RETURN a.id AS id
    "
    PARAMS="$(jq -n --arg id "$A_ID" --arg url "$A_URL" --arg title "$A_TITLE" --arg type "$A_TYPE" \
      --arg author "$A_AUTHOR" --argjson topics "$A_TOPICS_JSON" --arg excerpt "$A_EXCERPT" \
      '{id: $id, url: $url, title: $title, type: $type, author: $author, topics: $topics, excerpt: $excerpt}')"
    bash "$SCRIPT_DIR/bin/graph-wal.sh" append "$CYPHER" "$PARAMS" 2>/dev/null || true
    bash "$GS" query "$CYPHER" "$PARAMS"
    ;;

  check-implements)
    SID="${1:?missing session-id}"
    bash "$GS" query "
      MATCH (impl:Session {id: \$sid})-[:IMPLEMENTS]->(ho:Session)-[:BY]->(author:Person)
      RETURN ho.id AS handoffId, ho.topic AS topic, author.name AS author,
             author.github AS authorGithub
    " "$(jq -n --arg sid "$SID" '{sid: $sid}')"
    ;;

  update-pr)
    PR_NUM="${1:?missing pr-number}"
    REPO="${2:?missing repo}"
    STATUS="${3:?missing status}"
    MERGED_AT="${4:-}"
    if [ -n "$MERGED_AT" ]; then
      bash "$GS" query "
        MATCH (pr:PR {number: toInteger(\$num), repo: \$repo})
        SET pr.status = \$status, pr.mergedAt = datetime(\$mergedAt)
        RETURN pr.number AS number, pr.status AS status
      " "$(jq -n --argjson num "$PR_NUM" --arg repo "$REPO" --arg status "$STATUS" --arg mergedAt "$MERGED_AT" '{num: $num, repo: $repo, status: $status, mergedAt: $mergedAt}')"
    else
      bash "$GS" query "
        MATCH (pr:PR {number: toInteger(\$num), repo: \$repo})
        SET pr.status = \$status
        RETURN pr.number AS number, pr.status AS status
      " "$(jq -n --argjson num "$PR_NUM" --arg repo "$REPO" --arg status "$STATUS" '{num: $num, repo: $repo, status: $status}')"
    fi
    ;;

  my-merged-prs)
    AUTHOR_GH="${1:?missing author-github}"
    SINCE="${2:-}"
    if [ -n "$SINCE" ]; then
      bash "$GS" query "
        MATCH (pr:PR {author: \$author})
        WHERE pr.status = 'merged' AND pr.mergedAt >= datetime(\$since)
        RETURN pr.number AS number, pr.repo AS repo, pr.title AS title,
               toString(pr.mergedAt) AS mergedAt
        ORDER BY pr.mergedAt DESC LIMIT 10
      " "$(jq -n --arg author "$AUTHOR_GH" --arg since "${SINCE}T00:00:00Z" '{author: $author, since: $since}')"
    else
      bash "$GS" query "
        MATCH (pr:PR {author: \$author})
        WHERE pr.status = 'merged'
        RETURN pr.number AS number, pr.repo AS repo, pr.title AS title,
               toString(pr.mergedAt) AS mergedAt
        ORDER BY pr.mergedAt DESC LIMIT 5
      " "$(jq -n --arg author "$AUTHOR_GH" '{author: $author}')"
    fi
    ;;

  my-implemented-handoffs)
    AUTHOR_NAME="${1:?missing author-name}"
    SINCE="${2:-}"
    if [ -n "$SINCE" ]; then
      bash "$GS" query "
        MATCH (impl:Session)-[:IMPLEMENTS]->(ho:Session)-[:BY]->(author:Person)
        WHERE toLower(author.name) = toLower(\$author)
          AND impl.wrappedAt >= datetime(\$since)
        MATCH (impl)-[:BY]->(implementor:Person)
        RETURN ho.topic AS handoffTopic, implementor.name AS implementedBy,
               toString(impl.wrappedAt) AS completedAt, impl.summary AS summary
        ORDER BY impl.wrappedAt DESC LIMIT 10
      " "$(jq -n --arg author "$AUTHOR_NAME" --arg since "${SINCE}T00:00:00Z" '{author: $author, since: $since}')"
    else
      bash "$GS" query "
        MATCH (impl:Session)-[:IMPLEMENTS]->(ho:Session)-[:BY]->(author:Person)
        WHERE toLower(author.name) = toLower(\$author)
        MATCH (impl)-[:BY]->(implementor:Person)
        RETURN ho.topic AS handoffTopic, implementor.name AS implementedBy,
               toString(impl.wrappedAt) AS completedAt, impl.summary AS summary
        ORDER BY impl.wrappedAt DESC LIMIT 5
      " "$(jq -n --arg author "$AUTHOR_NAME" '{author: $author}')"
    fi
    ;;

  open-handoffs)
    USER="${1:?missing username}"
    LIMIT="${2:-10}"
    if ! [[ "$LIMIT" =~ ^[0-9]+$ ]] || [ "$LIMIT" -lt 1 ] || [ "$LIMIT" -gt 25 ]; then
      echo '{"error":"limit must be between 1 and 25"}'
      exit 2
    fi
    bash "$GS" query "
      MATCH (s:Session)-[:HANDED_TO]->(p:Person)
      WHERE NOT coalesce(p.kind, '') IN ['identity_alias']
        AND (
        toLower(coalesce(p.name, '')) = toLower(\$user)
        OR toLower(coalesce(p.github, '')) = toLower(\$user)
        OR toLower(coalesce(p.githubUsername, '')) = toLower(\$user)
        OR any(alias IN coalesce(p.previousNames, [])
               WHERE toLower(alias) = toLower(\$user))
      )
        AND coalesce(s.handoffStatus, 'pending')
            IN ['pending','unread','read','claimed']
      WITH DISTINCT s
      WITH s, head([(s)-[:BY]->(author:Person)
                    WHERE NOT coalesce(author.kind, '') IN ['identity_alias'] | author.name]) AS authorName,
           CASE WHEN s.date IS NULL THEN null
                ELSE duration.inDays(date(s.date), date()).days END AS ageDays
      RETURN s.id AS id,
             coalesce(s.topic, s.summary, s.branch) AS topic,
             coalesce(authorName, s.author, 'unknown') AS author,
             toString(s.date) AS date,
             coalesce(s.handoffStatus, 'pending') AS status,
             coalesce(s.handoffIntent, 'unclassified') AS intent,
             ageDays,
             CASE WHEN ageDays IS NULL THEN 'unknown'
                  WHEN ageDays <= 14 THEN 'current'
                  WHEN ageDays <= 30 THEN 'aging'
                  ELSE 'stale' END AS freshness,
             1 AS definitionVersion
      ORDER BY s.date DESC, s.id
      LIMIT \$limit
    " "$(jq -n --arg user "$USER" --argjson limit "$LIMIT" '{user: $user, limit: $limit}')"
    ;;

  pending-questions)
    USER="${1:?missing username}"
    LIMIT="${2:-10}"
    if ! [[ "$LIMIT" =~ ^[0-9]+$ ]] || [ "$LIMIT" -lt 1 ] || [ "$LIMIT" -gt 25 ]; then
      echo '{"error":"limit must be between 1 and 25"}'
      exit 2
    fi
    bash "$GS" query "
      MATCH (qs:QuestionSet)-[:ASKED_TO]->(p:Person)
      WHERE (
        toLower(coalesce(p.name, '')) = toLower(\$user)
        OR toLower(coalesce(p.github, '')) = toLower(\$user)
        OR toLower(coalesce(p.githubUsername, '')) = toLower(\$user)
        OR any(alias IN coalesce(p.previousNames, [])
               WHERE toLower(alias) = toLower(\$user))
      )
        AND coalesce(qs.status, 'pending') IN ['pending','active']
      WITH DISTINCT qs
      OPTIONAL MATCH (q:Question)-[:PART_OF]->(qs)
      OPTIONAL MATCH (qs)-[:ASKED_BY]->(asker:Person)
      WITH qs, asker, count(DISTINCT q) AS questions,
           CASE WHEN qs.created IS NULL THEN null
                ELSE duration.inDays(date(datetime(qs.created)), date()).days END AS ageDays
      RETURN qs.id AS id,
             qs.topic AS topic,
             coalesce(asker.name, qs.askedBy, qs.from, 'unknown') AS askedBy,
             questions,
             toString(qs.created) AS created,
             ageDays,
             CASE WHEN ageDays IS NULL THEN 'unknown'
                  WHEN ageDays <= 14 THEN 'current'
                  WHEN ageDays <= 30 THEN 'aging'
                  ELSE 'stale-open' END AS freshness,
             1 AS definitionVersion
      ORDER BY qs.created DESC, qs.id
      LIMIT \$limit
    " "$(jq -n --arg user "$USER" --argjson limit "$LIMIT" '{user: $user, limit: $limit}')"
    ;;

  lineage)
    QUERY="${1:?missing topic}"
    LIMIT="${2:-10}"
    if ! [[ "$LIMIT" =~ ^[0-9]+$ ]] || [ "$LIMIT" -lt 1 ] || [ "$LIMIT" -gt 15 ]; then
      echo '{"error":"limit must be between 1 and 15"}'
      exit 2
    fi
    GRAPH_RAW="$(bash "$GS" query "
      MATCH (s:Session)
      WHERE toLower(coalesce(s.topic, '')) CONTAINS toLower(\$query)
         OR toLower(coalesce(s.summary, '')) CONTAINS toLower(\$query)
         OR toLower(coalesce(s.branch, '')) CONTAINS toLower(\$query)
      OPTIONAL MATCH (s)-[:BY]->(author:Person)
      OPTIONAL MATCH (s)-[:HANDED_TO]->(recipient:Person)
      OPTIONAL MATCH (implementation:Session)-[:IMPLEMENTS]->(s)
      OPTIONAL MATCH (implementation)-[:BY]->(implementer:Person)
      OPTIONAL MATCH (s)-[:IMPLEMENTS]->(prior:Session)
      OPTIONAL MATCH (prior)-[:BY]->(priorAuthor:Person)
      OPTIONAL MATCH (s)-[:PRODUCED]->(pr:PR)
      OPTIONAL MATCH (implementation)-[:PRODUCED]->(implementationPr:PR)
      WITH s, author,
           collect(DISTINCT coalesce(recipient.name, recipient.github)) AS recipients,
           collect(DISTINCT CASE WHEN implementation IS NULL THEN null ELSE {
             id: implementation.id,
             topic: implementation.topic,
             summary: implementation.summary,
             branch: implementation.branch,
             date: toString(implementation.date),
             evidencePath: CASE
               WHEN implementation.filePath IS NULL THEN null
               WHEN implementation.filePath STARTS WITH 'memory/' THEN implementation.filePath
               ELSE 'memory/' + implementation.filePath END,
             implementedBy: coalesce(implementer.name, implementer.github)
           } END) AS implementations,
           collect(DISTINCT CASE WHEN prior IS NULL THEN null ELSE {
             id: prior.id,
             topic: prior.topic,
             summary: prior.summary,
             branch: prior.branch,
             date: toString(prior.date),
             evidencePath: CASE
               WHEN prior.filePath IS NULL THEN null
               WHEN prior.filePath STARTS WITH 'memory/' THEN prior.filePath
               ELSE 'memory/' + prior.filePath END,
             author: coalesce(priorAuthor.name, priorAuthor.github)
           } END) AS implements,
           collect(DISTINCT CASE WHEN pr IS NULL THEN null ELSE {
             number: pr.number, repo: pr.repo, title: pr.title,
             status: pr.status, mergedAt: toString(pr.mergedAt)
           } END)
           + collect(DISTINCT CASE WHEN implementationPr IS NULL THEN null ELSE {
             number: implementationPr.number, repo: implementationPr.repo,
             title: implementationPr.title, status: implementationPr.status,
             mergedAt: toString(implementationPr.mergedAt)
           } END) AS prs
      RETURN s.id AS sessionId,
             s.topic AS topic,
             s.summary AS summary,
             s.branch AS branch,
             toString(s.date) AS date,
             CASE WHEN s.filePath IS NULL THEN null
                  WHEN s.filePath STARTS WITH 'memory/' THEN s.filePath
                  ELSE 'memory/' + s.filePath END AS evidencePath,
             coalesce(author.name, author.github, s.author, 'unknown') AS author,
             recipients[0..20] AS recipients,
             implementations[0..10] AS implementations,
             implements[0..10] AS implements,
             prs[0..10] AS prs
      ORDER BY s.date DESC, s.id
      LIMIT \$limit
    " "$(jq -n --arg query "$QUERY" --argjson limit "$LIMIT" '{query:$query,limit:$limit}')")"
    FILES_RAW="$(memory_file_candidates "$QUERY" "$LIMIT" \
      "$SCRIPT_DIR/memory/handoffs" \
      "$SCRIPT_DIR/memory/wraps" \
      "$SCRIPT_DIR/memory/sessions")"
    jq -n \
      --arg query "$QUERY" \
      --argjson limit "$LIMIT" \
      --argjson graph "$GRAPH_RAW" \
      --argjson files "$FILES_RAW" '
      ($graph.values // [] | map({
        sessionId: .[0], topic: .[1], summary: .[2], branch: .[3],
        date: .[4], evidencePath: .[5], author: .[6],
        recipients: (.[7] // []), implementations: (.[8] // []),
        implements: (.[9] // []), prs: (.[10] // [])
      })) as $matches
      | ($matches | map(.evidencePath) | map(select(. != null)) | unique) as $graphPaths
      | ($files | map(.evidencePath) | unique) as $filePaths
      | ($filePaths - $graphPaths) as $unprojected
      | {
          schema: "egregore.graph-read/v1",
          operation: "lineage",
          definitionVersion: 1,
          query: $query,
          limit: $limit,
          coverage:
            (if ($graphPaths | length) == 0 then
               (if ($filePaths | length) == 0 then "none" else "filesystem-only" end)
             elif ($unprojected | length) > 0 then "partial"
             else "complete" end),
          graphMatches: $matches,
          fileCandidates:
            ($files | map(
              . as $candidate
              | . + {
                projection:
                  (if ($graphPaths | index($candidate.evidencePath)) != null
                   then "projected" else "unprojected" end)
              }
            )),
          unprojectedPaths: $unprojected
        }
    '
    ;;

  meeting-history)
    QUERY="${1:?missing company, person, or topic}"
    LIMIT="${2:-10}"
    if ! [[ "$LIMIT" =~ ^[0-9]+$ ]] || [ "$LIMIT" -lt 1 ] || [ "$LIMIT" -gt 15 ]; then
      echo '{"error":"limit must be between 1 and 15"}'
      exit 2
    fi
    QUERY_TERMS="$(meaningful_query_terms "$QUERY")"
    GRAPH_RAW="$(bash "$GS" query "
      MATCH (m:Meeting)
      OPTIONAL MATCH (m)-[:INVOLVES|CONDUCTED_BY]->(participant:Person)
      WITH m, collect(DISTINCT participant) AS participants
      WITH m, participants,
           [term IN \$terms WHERE
             toLower(coalesce(m.title, '')) CONTAINS term
             OR toLower(coalesce(m.name, '')) CONTAINS term
             OR toLower(coalesce(m.id, '')) CONTAINS term
             OR any(p IN participants WHERE
                  toLower(coalesce(p.name, '')) CONTAINS term
                  OR toLower(coalesce(p.github, '')) CONTAINS term)
           ] AS matchedTerms
      WHERE size(matchedTerms) > 0
      OPTIONAL MATCH (artifact:Artifact)-[:FROM_MEETING]->(m)
      RETURN m.id AS meetingId,
             coalesce(m.title, m.name, m.id) AS title,
             toString(m.date) AS date,
             CASE WHEN m.filePath IS NULL THEN null
                  WHEN m.filePath STARTS WITH 'memory/' THEN m.filePath
                  ELSE 'memory/' + m.filePath END AS evidencePath,
             ([p IN participants | coalesce(p.name, p.github)])[0..20] AS participants,
             (collect(DISTINCT CASE WHEN artifact IS NULL THEN null ELSE {
               id: artifact.id,
               type: artifact.type,
               title: artifact.title,
               summary: artifact.summary,
               evidencePath: CASE
                 WHEN artifact.filePath IS NULL THEN null
                 WHEN artifact.filePath STARTS WITH 'memory/' THEN artifact.filePath
                 ELSE 'memory/' + artifact.filePath END
             } END))[0..10] AS derivedKnowledge,
             coalesce(m.verificationStatus, 'legacy') AS verificationStatus,
             m.ingestManifestId AS ingestManifestId,
             matchedTerms,
             size(matchedTerms) AS matchScore
      ORDER BY matchScore DESC, date ASC, meetingId
      LIMIT \$limit
    " "$(jq -n --arg query "$QUERY" --argjson terms "$QUERY_TERMS" --argjson limit "$LIMIT" \
      '{query:$query,terms:$terms,limit:$limit}')")"
    FILES_RAW="$(memory_file_candidates_for_terms \
      "$QUERY_TERMS" "$LIMIT" "$SCRIPT_DIR/memory/meetings")"
    jq -n \
      --arg query "$QUERY" \
      --argjson queryTerms "$QUERY_TERMS" \
      --argjson limit "$LIMIT" \
      --argjson graph "$GRAPH_RAW" \
      --argjson files "$FILES_RAW" '
      ($graph.values // [] | map({
        meetingId: .[0], title: .[1], date: .[2], evidencePath: .[3],
        participants: (.[4] // []), derivedKnowledge: (.[5] // []),
        verificationStatus: .[6], ingestManifestId: .[7],
        matchedTerms: (.[8] // []), matchScore: (.[9] // 0)
      })) as $meetings
      | ($meetings | map(.evidencePath) | map(select(. != null)) | unique) as $graphPaths
      | ($files | map(.evidencePath) | unique) as $filePaths
      | ($filePaths - $graphPaths) as $unprojected
      | {
          schema: "egregore.graph-read/v1",
          operation: "meeting-history",
          definitionVersion: 1,
          query: $query,
          queryTerms: $queryTerms,
          limit: $limit,
          coverage:
            (if ($graphPaths | length) == 0 then
               (if ($filePaths | length) == 0 then "none" else "filesystem-only" end)
             elif ($unprojected | length) > 0 then "partial"
             else "complete" end),
          graphMeetings: $meetings,
          fileCandidates:
            ($files | map(
              . as $candidate
              | . + {
                projection:
                  (if ($graphPaths | index($candidate.evidencePath)) != null
                   then "projected" else "unprojected" end)
              }
            )),
          unprojectedPaths: $unprojected
        }
    '
    ;;

  wal-status)
    bash "$SCRIPT_DIR/bin/graph-wal.sh" status
    ;;

  create-harvest)
    HID="${1:?missing harvest-id}"
    TOPIC="${2:?missing topic}"
    INTENT="${3:?missing intent}"
    INITIATOR="${4:?missing initiator}"
    CYPHER="
      MERGE (h:Harvest {id: \$hid})
      ON CREATE SET h.topic = \$topic, h.intent = \$intent,
        h.status = 'active', h.created = datetime()
      WITH h
      MATCH (p:Person) WHERE toLower(p.name) = toLower(\$initiator) OR p.github = \$initiator
      MERGE (h)-[:INITIATED_BY]->(p)
      RETURN h.id AS id, h.topic AS topic, h.status AS status
    "
    PARAMS="$(jq -n --arg hid "$HID" --arg topic "$TOPIC" --arg intent "$INTENT" --arg initiator "$INITIATOR" '{hid: $hid, topic: $topic, intent: $intent, initiator: $initiator}')"
    bash "$SCRIPT_DIR/bin/graph-wal.sh" append "$CYPHER" "$PARAMS" 2>/dev/null || true
    bash "$GS" query "$CYPHER" "$PARAMS"
    ;;

  create-harvest-session)
    HID="${1:?missing harvest-id}"
    HSID="${2:?missing session-id}"
    PERSON="${3:?missing person-name}"
    STATUS="${4:-active}"
    case "$STATUS" in
      pending|active|answered|complete|incorporated) ;;
      *) jq -n --arg s "$STATUS" '{error:("invalid status: "+$s),valid:["pending","active","answered","complete","incorporated"]}' >&2; exit 2 ;;
    esac
    CYPHER="
      MATCH (h:Harvest {id: \$hid})
      MERGE (hs:HarvestSession {id: \$hsid})
      ON CREATE SET hs.status = \$status, hs.created = datetime()
      MERGE (h)-[:HAS_SESSION]->(hs)
      WITH hs
      MATCH (p:Person) WHERE toLower(p.name) = toLower(\$person) OR p.github = \$person
      MERGE (hs)-[:WITH]->(p)
      RETURN hs.id AS id, hs.status AS status
    "
    PARAMS="$(jq -n --arg hid "$HID" --arg hsid "$HSID" --arg person "$PERSON" --arg status "$STATUS" '{hid: $hid, hsid: $hsid, person: $person, status: $status}')"
    bash "$SCRIPT_DIR/bin/graph-wal.sh" append "$CYPHER" "$PARAMS" 2>/dev/null || true
    OUT="$(bash "$GS" query "$CYPHER" "$PARAMS")"
    if [ "$(echo "$OUT" | jq -r '.results | length' 2>/dev/null)" = "0" ]; then
      jq -n --arg hid "$HID" --arg hsid "$HSID" --arg person "$PERSON" \
        '{error:"create-harvest-session: harvest or person not found",hid:$hid,hsid:$hsid,person:$person}' >&2
      exit 3
    fi
    echo "$OUT"
    ;;

  record-harvest-turn)
    HSID="${1:?missing session-id}"
    TURN="${2:?missing turn-number}"
    QUESTION="${3:?missing question}"
    QINTENT="${4:?missing question-intent}"
    ANSWER="${5:-}"
    EVAL="${6:-}"
    TURN_ID="${HSID}-turn-${TURN}"
    PARAMS=$(jq -n \
      --arg hsid "$HSID" --arg tid "$TURN_ID" --arg turn "$TURN" \
      --arg question "$QUESTION" --arg qintent "$QINTENT" \
      --arg answer "$ANSWER" --arg eval "$EVAL" \
      '{hsid:$hsid, tid:$tid, turn:$turn, question:$question, qintent:$qintent, answer:$answer, eval:$eval}')
    if [ -n "$ANSWER" ]; then
      bash "$GS" query "
        MATCH (hs:HarvestSession {id: \$hsid})
        MERGE (t:HarvestTurn {id: \$tid})
        ON CREATE SET t.turnNumber = toInteger(\$turn), t.question = \$question,
          t.questionIntent = \$qintent, t.created = datetime()
        SET t.answer = \$answer, t.answeredAt = datetime()
        SET t.evaluation = CASE WHEN \$eval <> '' THEN \$eval ELSE t.evaluation END
        MERGE (hs)-[:HAS_TURN]->(t)
        RETURN t.id AS id, t.turnNumber AS turnNumber
      " "$PARAMS"
    else
      bash "$GS" query "
        MATCH (hs:HarvestSession {id: \$hsid})
        MERGE (t:HarvestTurn {id: \$tid})
        ON CREATE SET t.turnNumber = toInteger(\$turn), t.question = \$question,
          t.questionIntent = \$qintent, t.created = datetime()
        MERGE (hs)-[:HAS_TURN]->(t)
        RETURN t.id AS id, t.turnNumber AS turnNumber
      " "$PARAMS"
    fi
    ;;

  complete-harvest)
    HID="${1:?missing harvest-id}"
    ARTIFACT_PATH="${2:?missing artifact-path}"
    bash "$GS" query "
      MATCH (h:Harvest {id: \$hid})
      SET h.status = 'complete', h.completedAt = datetime(), h.synthesisPath = \$path
      WITH h
      OPTIONAL MATCH (h)-[:HAS_SESSION]->(hs:HarvestSession)
      WHERE hs.status <> 'complete'
      SET hs.status = 'complete', hs.completedAt = datetime()
      WITH h
      MERGE (a:Artifact {id: \$hid + '-synthesis'})
      ON CREATE SET a.type = 'harvest', a.title = h.topic, a.filePath = \$path,
        a.created = datetime(), a.topics = coalesce([h.topic], [])
      MERGE (h)-[:PRODUCED]->(a)
      RETURN h.id AS id, h.status AS status, a.id AS artifact
    " "$(jq -n --arg hid "$HID" --arg path "$ARTIFACT_PATH" '{hid: $hid, path: $path}')"
    ;;

  *)
    echo '{"error":"unknown operation: '"$OP"'","operations":["catalog","people","open-quests","spirit-context","spirit-list","spirit-create","spirit-update","register-emissary","register-eval-report","register-artifact","mark-read","mark-done","mark-expired","reopen-handoff","answer-question","resolve-handoffs","set-topic","record-focus","merge-person","claim-handoff","claim-handoff-nudge","mark-handoff-nudged","release-handoff-nudge","check-implements","create-pr","record-pr","update-pr","my-merged-prs","my-implemented-handoffs","open-handoffs","pending-questions","lineage","meeting-history","wal-status","create-harvest","create-harvest-session","record-harvest-turn","complete-harvest"]}'
    exit 1
    ;;

esac
