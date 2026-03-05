#!/bin/bash
set -euo pipefail
# Named graph operations — clean interface over raw Cypher.
# Keeps implementation details out of the TUI.
#
# Usage: bash bin/graph-op.sh <operation> [args...]
#
# Operations:
#   mark-read <session-id>      Mark a handoff as read
#   mark-done <session-id>      Mark a handoff as done/resolved
#   answer-question <set-id>    Mark a question set as answered
#   resolve-handoffs <user>     Auto-resolve read handoffs with later sessions
#   set-topic <session-id> <topic> [branch]
#                               Set topic (and optionally branch) on a Session node
#   record-focus <session-id> <shown-json> <selected> [dismissed-json]
#                               Track Focus option selection for adaptive options
#   merge-person <keep-name> <remove-name>
#                               Merge two Person nodes — transfers relationships from
#                               remove-name to keep-name, stores remove-name as alias

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GS="$SCRIPT_DIR/bin/graph.sh"

OP="${1:-}"
shift || true

case "$OP" in

  mark-read)
    SID="${1:?missing session-id}"
    bash "$GS" query "
      MATCH (s:Session {id: \$sid})
      SET s.handoffStatus = 'read', s.handoffReadDate = date()
      RETURN s.id AS id, s.topic AS topic
    " "{\"sid\":\"$SID\"}"
    ;;

  mark-done)
    SID="${1:?missing session-id}"
    bash "$GS" query "
      MATCH (s:Session {id: \$sid})
      SET s.handoffStatus = 'done'
      RETURN s.id AS id, s.topic AS topic
    " "{\"sid\":\"$SID\"}"
    ;;

  answer-question)
    QID="${1:?missing question-set-id}"
    bash "$GS" query "
      MATCH (qs:QuestionSet {id: \$qid})
      SET qs.status = 'answered'
      RETURN qs.id AS id, qs.topic AS topic
    " "{\"qid\":\"$QID\"}"
    ;;

  resolve-handoffs)
    USER="${1:?missing username}"
    bash "$GS" query "
      MATCH (s:Session)-[:HANDED_TO]->(p:Person {name: \$user})
      WHERE s.handoffStatus = 'read'
      WITH s, p, coalesce(s.handoffReadDate, s.date) AS sinceDate
      MATCH (later:Session)-[:BY]->(p)
      WHERE later.date > sinceDate
      WITH s, count(later) AS laterSessions WHERE laterSessions > 0
      SET s.handoffStatus = 'done'
      RETURN s.id AS resolved
    " "{\"user\":\"$USER\"}"
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
      " "{\"sid\":\"$SID\",\"topic\":\"$TOPIC\",\"branch\":\"$BRANCH\"}"
    else
      bash "$GS" query "
        MATCH (s:Session {id: \$sid})
        SET s.topic = \$topic
        RETURN s.id AS id, s.topic AS topic
      " "{\"sid\":\"$SID\",\"topic\":\"$TOPIC\"}"
    fi
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
    " "{\"sid\":\"$SID\",\"shown\":$SHOWN,\"selected\":\"$SELECTED\",\"dismissed\":$DISMISSED}"
    ;;

  merge-person)
    KEEP="${1:?missing keep-name (the Person to keep)}"
    REMOVE="${2:?missing remove-name (the Person to absorb)}"
    bash "$GS" query "
      MATCH (keep:Person) WHERE toLower(keep.name) = toLower(\$keep) OR keep.github = \$keep
      MATCH (remove:Person) WHERE toLower(remove.name) = toLower(\$remove) OR remove.github = \$remove
      WITH keep, remove WHERE keep <> remove
      SET keep.previousNames = coalesce(keep.previousNames, []) + remove.name
      WITH keep, remove
      OPTIONAL MATCH (s1)-[:BY]->(remove)
      FOREACH (_ IN CASE WHEN s1 IS NOT NULL THEN [1] ELSE [] END | MERGE (s1)-[:BY]->(keep))
      WITH keep, remove
      OPTIONAL MATCH (s2)-[:HANDED_TO]->(remove)
      FOREACH (_ IN CASE WHEN s2 IS NOT NULL THEN [1] ELSE [] END | MERGE (s2)-[:HANDED_TO]->(keep))
      WITH keep, remove
      OPTIONAL MATCH (m)-[:INVOLVES]->(remove)
      FOREACH (_ IN CASE WHEN m IS NOT NULL THEN [1] ELSE [] END | MERGE (m)-[:INVOLVES]->(keep))
      WITH keep, remove
      OPTIONAL MATCH (a)-[:CONTRIBUTED_BY]->(remove)
      FOREACH (_ IN CASE WHEN a IS NOT NULL THEN [1] ELSE [] END | MERGE (a)-[:CONTRIBUTED_BY]->(keep))
      WITH keep, remove
      OPTIONAL MATCH (i)-[:CONDUCTED_BY]->(remove)
      FOREACH (_ IN CASE WHEN i IS NOT NULL THEN [1] ELSE [] END | MERGE (i)-[:CONDUCTED_BY]->(keep))
      WITH keep, remove
      OPTIONAL MATCH (remove)-[:MEMBER_OF]->(o:Org)
      FOREACH (_ IN CASE WHEN o IS NOT NULL THEN [1] ELSE [] END | MERGE (keep)-[:MEMBER_OF]->(o))
      WITH keep, remove
      DETACH DELETE remove
      RETURN keep.name AS name, keep.github AS github, keep.previousNames AS aliases
    " "{\"keep\":\"$KEEP\",\"remove\":\"$REMOVE\"}"
    ;;

  wal-status)
    bash "$SCRIPT_DIR/bin/graph-wal.sh" status
    ;;

  *)
    echo '{"error":"unknown operation: '"$OP"'","operations":["mark-read","mark-done","answer-question","resolve-handoffs","set-topic","record-focus","merge-person","wal-status"]}'
    exit 1
    ;;

esac
