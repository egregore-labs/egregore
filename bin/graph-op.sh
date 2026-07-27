#!/usr/bin/env bash
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
#   create-harvest <id> <topic> <intent> <initiator>
#                               Create a Harvest node and link to initiator (WAL-backed)
#   create-harvest-session <harvest-id> <session-id> <person-name>
#                               Create a HarvestSession linked to a Harvest and Person
#   record-harvest-turn <session-id> <turn> <question> <intent> [answer] [eval]
#                               Record a question-answer turn in a HarvestSession
#   complete-harvest <harvest-id> <artifact-path>
#                               Mark harvest complete and link synthesis artifact

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  echo "Usage: graph-op.sh <operation> [args...]"
  echo ""
  echo "Named graph operations — clean interface over raw Cypher."
  echo ""
  echo "Operations:"
  echo "  mark-read <sid>          Mark handoff as read"
  echo "  mark-done <sid>          Mark handoff as done"
  echo "  answer-question <qid>    Mark question set as answered"
  echo "  resolve-handoffs <user>  Auto-resolve read handoffs"
  echo "  set-topic <sid> <topic>  Set topic on a Session node"
  echo "  merge-person <keep> <rm> Merge two Person nodes"
  echo "  claim-handoff <sid> <ho> Link implementing session to handoff"
  echo "  create-pr <sid> <num> <repo> <author> [title]"
  echo "  create-harvest / complete-harvest / record-harvest-turn"
  echo "  wal-status               Show WAL pending count"
  exit 0
fi

# --- Local mode gate: bail immediately ---
_MODE=$(jq -r '.mode // "connected"' "$SCRIPT_DIR/egregore.json" 2>/dev/null)
if [ "$_MODE" = "local" ]; then
  echo '{"results":[]}'
  exit 0
fi

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
    " "$(jq -n --arg sid "$SID" '{sid: $sid}')"
    ;;

  mark-done)
    SID="${1:?missing session-id}"
    bash "$GS" query "
      MATCH (s:Session {id: \$sid})
      SET s.handoffStatus = 'done'
      RETURN s.id AS id, s.topic AS topic
    " "$(jq -n --arg sid "$SID" '{sid: $sid}')"
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
      WHERE s.handoffStatus = 'read'
      WITH s, p, coalesce(s.handoffReadDate, s.date) AS sinceDate
      MATCH (later:Session)-[:BY]->(p)
      WHERE later.date > sinceDate
      WITH s, count(later) AS laterSessions WHERE laterSessions > 0
      SET s.handoffStatus = 'done'
      RETURN s.id AS resolved
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
    " "$(jq -n --arg keep "$KEEP" --arg remove "$REMOVE" '{keep: $keep, remove: $remove}')"
    ;;

  claim-handoff)
    IMPL_SID="${1:?missing implementing-session-id}"
    HO_SID="${2:?missing handoff-session-id}"
    CYPHER="
      MATCH (impl:Session {id: \$implSid}), (ho:Session {id: \$hoSid})
      WHERE ho.handoffStatus IS NOT NULL
      MERGE (impl)-[:IMPLEMENTS]->(ho)
      RETURN impl.id AS implementor, ho.id AS handoff, ho.topic AS topic
    "
    PARAMS="$(jq -n --arg implSid "$IMPL_SID" --arg hoSid "$HO_SID" '{implSid: $implSid, hoSid: $hoSid}')"
    bash "$SCRIPT_DIR/bin/graph-wal.sh" append "$CYPHER" "$PARAMS" 2>/dev/null || true
    bash "$GS" query "$CYPHER" "$PARAMS"
    ;;

  create-pr)
    SID="${1:?missing session-id}"
    PR_NUM="${2:?missing pr-number}"
    REPO="${3:?missing repo}"
    AUTHOR_GH="${4:?missing author-github}"
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
    bash "$GS" query "
      MATCH (h:Harvest {id: \$hid})
      MERGE (hs:HarvestSession {id: \$hsid})
      ON CREATE SET hs.status = 'active', hs.created = datetime()
      MERGE (h)-[:HAS_SESSION]->(hs)
      WITH hs
      MATCH (p:Person) WHERE toLower(p.name) = toLower(\$person) OR p.github = \$person
      MERGE (hs)-[:WITH]->(p)
      RETURN hs.id AS id, hs.status AS status
    " "$(jq -n --arg hid "$HID" --arg hsid "$HSID" --arg person "$PERSON" '{hid: $hid, hsid: $hsid, person: $person}')"
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
    echo '{"error":"unknown operation: '"$OP"'","operations":["mark-read","mark-done","answer-question","resolve-handoffs","set-topic","record-focus","merge-person","claim-handoff","check-implements","create-pr","update-pr","my-merged-prs","my-implemented-handoffs","wal-status","create-harvest","create-harvest-session","record-harvest-turn","complete-harvest"]}'
    exit 1
    ;;

esac
