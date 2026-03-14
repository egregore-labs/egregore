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
#   create-harvest <id> <topic> <intent> <initiator>
#                               Create a Harvest node with INITIATED_BY link
#   create-harvest-session <harvest-id> <session-id> <person-name>
#                               Create a HarvestSession linked to Harvest and Person
#   record-harvest-turn <session-id> <turn-num> <question> <intent> [answer] [evaluation]
#                               Record a question-answer turn in a HarvestSession
#   complete-harvest <harvest-id> <synthesis-path>
#                               Mark harvest complete, create Artifact, link via PRODUCED

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

  claim-handoff)
    IMPL_SID="${1:?missing implementing-session-id}"
    HO_SID="${2:?missing handoff-session-id}"
    CYPHER="
      MATCH (impl:Session {id: \$implSid}), (ho:Session {id: \$hoSid})
      WHERE ho.handoffStatus IS NOT NULL
      MERGE (impl)-[:IMPLEMENTS]->(ho)
      RETURN impl.id AS implementor, ho.id AS handoff, ho.topic AS topic
    "
    PARAMS="{\"implSid\":\"$IMPL_SID\",\"hoSid\":\"$HO_SID\"}"
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
    PARAMS="{\"sid\":\"$SID\",\"num\":$PR_NUM,\"repo\":\"$REPO\",\"author\":\"$AUTHOR_GH\",\"title\":\"$TITLE\"}"
    bash "$SCRIPT_DIR/bin/graph-wal.sh" append "$CYPHER" "$PARAMS" 2>/dev/null || true
    bash "$GS" query "$CYPHER" "$PARAMS"
    ;;

  check-implements)
    SID="${1:?missing session-id}"
    bash "$GS" query "
      MATCH (impl:Session {id: \$sid})-[:IMPLEMENTS]->(ho:Session)-[:BY]->(author:Person)
      RETURN ho.id AS handoffId, ho.topic AS topic, author.name AS author,
             author.github AS authorGithub
    " "{\"sid\":\"$SID\"}"
    ;;

  update-pr)
    PR_NUM="${1:?missing pr-number}"
    REPO="${2:?missing repo}"
    STATUS="${3:?missing status}"
    MERGED_AT="${4:-}"
    if [ -n "$MERGED_AT" ]; then

mark-dormant)
    QID="${1:?missing quest-id}"
    bash "$GS" query "
      MATCH (q:Quest {id: \$qid})
      WHERE q.status = 'active'
      SET q.status = 'dormant', q.dormantSince = date()
      RETURN q.id AS id, q.title AS title, q.status AS status
    " "{\"qid\":\"$QID\"}"
    ;;

  expire-handoffs)
    # Mark pending handoffs older than 30 days as expired
    bash "$GS" query "
      MATCH (s:Session)-[:HANDED_TO]->(:Person)
      WHERE s.handoffStatus = 'pending' AND s.date < date() - duration('P30D')
      SET s.handoffStatus = 'expired', s.expiredAt = date()
      RETURN count(s) AS expired, collect(s.id) AS ids
    "
    ;;

  auto-link-topics)
    # Link artifacts to quests using TF-IDF weighted topic specificity.
    # Rare topics contribute more than common ones (onboarding, architecture).
    # Links to ALL quests above threshold — multi-quest, not winner-take-all.
    # Step 1: Compute IDF table (how rare each topic is across all artifacts)
    # Step 2: For each unlinked artifact x quest pair, score by sum of shared topic IDFs
    # Step 3: Link to ALL quests scoring above threshold (multi-quest, not winner-take-all)
    # Step 4: Store specificity score on edge for Witness quality evaluation
    bash "$GS" query "
      MATCH (allA:Artifact)
      WHERE allA.topics IS NOT NULL
      UNWIND allA.topics AS t
      WITH t, count(allA) AS docFreq
      WITH collect({topic: t, idf: 1.0 / log(toFloat(docFreq) + 1.0)}) AS idfTable
      MATCH (a:Artifact)
      WHERE NOT (a)-[:PART_OF]->(:Quest) AND a.topics IS NOT NULL AND size(a.topics) > 0
      MATCH (q:Quest)
      WHERE q.topics IS NOT NULL AND size(q.topics) > 0
      WITH a, q, idfTable, [t IN a.topics WHERE t IN q.topics] AS shared
      WHERE size(shared) > 0
      WITH a, q, shared,
        reduce(score = 0.0, t IN shared |
          score + coalesce([x IN idfTable WHERE x.topic = t | x.idf][0], 0.1)
        ) AS specificity
      WHERE specificity > 0.5
      MERGE (a)-[r:PART_OF]->(q)
      SET r.specificity = round(specificity * 100.0) / 100.0,
          r.sharedTopics = shared,
          r.createdBy = 'graph-maintenance-tfidf'
      RETURN a.id AS artifact, q.id AS quest, shared AS sharedTopics,
             round(specificity * 100.0) / 100.0 AS score
      ORDER BY score DESC
    "
    ;;

  migrate-dates)
    LABEL="${1:?missing label (Session or Artifact)}"
    PROP="${2:?missing property (date or created)}"
    # Guard: only allow known label+property combos
    if [[ "$LABEL" == "Session" && "$PROP" == "date" ]]; then
      bash "$GS" query "
        MATCH (pr:PR {number: toInteger(\$num), repo: \$repo})
        SET pr.status = \$status, pr.mergedAt = datetime(\$mergedAt)
        RETURN pr.number AS number, pr.status AS status
      " "{\"num\":$PR_NUM,\"repo\":\"$REPO\",\"status\":\"$STATUS\",\"mergedAt\":\"$MERGED_AT\"}"
    else
      bash "$GS" query "
        MATCH (pr:PR {number: toInteger(\$num), repo: \$repo})
        SET pr.status = \$status
        RETURN pr.number AS number, pr.status AS status
      " "{\"num\":$PR_NUM,\"repo\":\"$REPO\",\"status\":\"$STATUS\"}"
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
      " "{\"author\":\"$AUTHOR_GH\",\"since\":\"${SINCE}T00:00:00Z\"}"
    else
      bash "$GS" query "
        MATCH (pr:PR {author: \$author})
        WHERE pr.status = 'merged'
        RETURN pr.number AS number, pr.repo AS repo, pr.title AS title,
               toString(pr.mergedAt) AS mergedAt
        ORDER BY pr.mergedAt DESC LIMIT 5
      " "{\"author\":\"$AUTHOR_GH\"}"
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
      " "{\"author\":\"$AUTHOR_NAME\",\"since\":\"${SINCE}T00:00:00Z\"}"
    else
      bash "$GS" query "
        MATCH (impl:Session)-[:IMPLEMENTS]->(ho:Session)-[:BY]->(author:Person)
        WHERE toLower(author.name) = toLower(\$author)
        MATCH (impl)-[:BY]->(implementor:Person)
        RETURN ho.topic AS handoffTopic, implementor.name AS implementedBy,
               toString(impl.wrappedAt) AS completedAt, impl.summary AS summary
        ORDER BY impl.wrappedAt DESC LIMIT 5
      " "{\"author\":\"$AUTHOR_NAME\"}"
    fi
    ;;

  create-harvest)
    HID="${1:?missing harvest-id}"
    TOPIC="${2:?missing topic}"
    INTENT="${3:?missing intent}"
    INITIATOR="${4:?missing initiator}"
    bash "$GS" query "
      MATCH (p:Person {name: \$initiator})
      CREATE (h:Harvest {
        id: \$hid,
        topic: \$topic,
        intent: \$intent,
        status: 'active',
        created: datetime()
      })
      CREATE (h)-[:INITIATED_BY]->(p)
      RETURN h.id AS id
    " "{\"hid\":\"$HID\",\"topic\":\"$TOPIC\",\"intent\":\"$INTENT\",\"initiator\":\"$INITIATOR\"}"
    ;;

  create-harvest-session)
    HID="${1:?missing harvest-id}"
    HSID="${2:?missing session-id}"
    PERSON="${3:?missing person-name}"
    bash "$GS" query "
      MATCH (h:Harvest {id: \$hid})
      MATCH (p:Person {name: \$person})
      CREATE (hs:HarvestSession {
        id: \$hsid,
        status: 'active',
        created: datetime()
      })
      CREATE (h)-[:HAS_SESSION]->(hs)
      CREATE (hs)-[:WITH]->(p)
      RETURN hs.id AS id
    " "{\"hid\":\"$HID\",\"hsid\":\"$HSID\",\"person\":\"$PERSON\"}"
    ;;

  record-harvest-turn)
    HSID="${1:?missing session-id}"
    TURN="${2:?missing turn-number}"
    QUESTION="${3:?missing question}"
    QINTENT="${4:?missing question-intent}"
    ANSWER="${5:-}"
    EVAL="${6:-}"
    if [ -n "$ANSWER" ]; then
      bash "$GS" query "
        MATCH (hs:HarvestSession {id: \$hsid})
        CREATE (t:HarvestTurn {
          id: \$hsid + '-turn-' + \$turn,
          turnNumber: toInteger(\$turn),
          question: \$question,
          questionIntent: \$qintent,
          answer: \$answer,
          evaluation: \$eval,
          created: datetime(),
          answeredAt: datetime()
        })
        CREATE (hs)-[:HAS_TURN]->(t)
        RETURN t.id AS id
      " "{\"hsid\":\"$HSID\",\"turn\":\"$TURN\",\"question\":\"$QUESTION\",\"qintent\":\"$QINTENT\",\"answer\":\"$ANSWER\",\"eval\":\"$EVAL\"}"
    else
      bash "$GS" query "
        MATCH (hs:HarvestSession {id: \$hsid})
        CREATE (t:HarvestTurn {
          id: \$hsid + '-turn-' + \$turn,
          turnNumber: toInteger(\$turn),
          question: \$question,
          questionIntent: \$qintent,
          created: datetime()
        })
        CREATE (hs)-[:HAS_TURN]->(t)
        RETURN t.id AS id
      " "{\"hsid\":\"$HSID\",\"turn\":\"$TURN\",\"question\":\"$QUESTION\",\"qintent\":\"$QINTENT\"}"
    fi
    ;;

  complete-harvest)
    HID="${1:?missing harvest-id}"
    SPATH="${2:?missing synthesis-path}"
    bash "$GS" query "
      MATCH (h:Harvest {id: \$hid})
      SET h.status = 'complete', h.completedAt = datetime(), h.synthesisPath = \$spath
      WITH h
      CREATE (a:Artifact {
        id: \$hid + '-synthesis',
        title: 'Harvest synthesis: ' + h.topic,
        type: 'harvest',
        filePath: \$spath,
        created: datetime()
      })
      CREATE (h)-[:PRODUCED]->(a)
      WITH h
      OPTIONAL MATCH (h)-[:HAS_SESSION]->(hs)
      SET hs.status = 'complete', hs.completedAt = datetime()
      RETURN h.id AS id, h.status AS status
    " "{\"hid\":\"$HID\",\"spath\":\"$SPATH\"}"
    ;;

  derive-topics)
    # Derive topics from artifact titles when topics are null/empty
    # Extracts keywords: lowercase, split on spaces/hyphens, filter stop words, take top 4
    bash "$GS" query "
      MATCH (a:Artifact)
      WHERE (a.topics IS NULL OR size(a.topics) = 0) AND a.title IS NOT NULL
      WITH a,
        [word IN split(toLower(a.title), ' ')
         WHERE size(word) > 2
           AND NOT word IN ['the','and','for','with','from','into','that','this','are','was','has','have','will','can','its','but','not','all','also','been','more','than','very','about','just','over','such','after','other','which','their','would','there','each','make','like','does','most','only','some','them','these','those','then','what','when','where','who','how']
        | word] AS words
      WHERE size(words) > 0
      SET a.topics = words[..4], a.topicsSource = 'derived-from-title'
      RETURN a.id AS id, a.title AS title, a.topics AS topics
    "
    ;;

  link-sessions-quests)
    # Infer Session-[:ADVANCED]->Quest from artifact linkage
    # If a session's author contributed artifacts to a quest, the session relates to that quest
    bash "$GS" query "
      MATCH (s:Session)-[:BY]->(p:Person)<-[:CONTRIBUTED_BY]-(a:Artifact)-[:PART_OF]->(q:Quest)
      WHERE NOT (s)-[:ADVANCED]->(q)
        AND s.date IS NOT NULL AND a.created IS NOT NULL
        AND date(left(toString(s.date), 10)) = date(left(toString(a.created), 10))
      MERGE (s)-[r:ADVANCED]->(q)
      SET r.createdBy = 'graph-maintenance', r.via = 'artifact-linkage'
      RETURN count(r) AS created
    "
    ;;

  relate-by-title)
    # RELATES_TO between artifacts with similar titles (sharing 2+ non-trivial words)
    # Only for artifacts not already related
    bash "$GS" query "
      MATCH (a1:Artifact), (a2:Artifact)
      WHERE a1 <> a2 AND id(a1) < id(a2)
        AND a1.title IS NOT NULL AND a2.title IS NOT NULL
        AND NOT (a1)-[:RELATES_TO]-(a2)
      WITH a1, a2,
        [w1 IN split(toLower(a1.title), ' ')
         WHERE size(w1) > 3
           AND NOT w1 IN ['the','and','for','with','from','into','that','this','egregore']
        ] AS words1,
        [w2 IN split(toLower(a2.title), ' ')
         WHERE size(w2) > 3
           AND NOT w2 IN ['the','and','for','with','from','into','that','this','egregore']
        ] AS words2
      WITH a1, a2, [w IN words1 WHERE w IN words2] AS shared
      WHERE size(shared) >= 2
      MERGE (a1)-[r:RELATES_TO]->(a2)
      SET r.sharedWords = shared, r.reason = 'title-similarity', r.createdBy = 'graph-maintenance'
      RETURN a1.id AS a, a2.id AS b, shared
    "
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
    PARAMS="{\"sid\":\"$SID\",\"num\":$PR_NUM,\"repo\":\"$REPO\",\"author\":\"$AUTHOR_GH\",\"title\":\"$TITLE\"}"
    bash "$SCRIPT_DIR/bin/graph-wal.sh" append "$CYPHER" "$PARAMS" 2>/dev/null || true
    bash "$GS" query "$CYPHER" "$PARAMS"
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
      " "{\"num\":$PR_NUM,\"repo\":\"$REPO\",\"status\":\"$STATUS\",\"mergedAt\":\"$MERGED_AT\"}"
    else
      bash "$GS" query "
        MATCH (pr:PR {number: toInteger(\$num), repo: \$repo})
        SET pr.status = \$status
        RETURN pr.number AS number, pr.status AS status
      " "{\"num\":$PR_NUM,\"repo\":\"$REPO\",\"status\":\"$STATUS\"}"
    fi
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
    PARAMS="{\"implSid\":\"$IMPL_SID\",\"hoSid\":\"$HO_SID\"}"
    bash "$SCRIPT_DIR/bin/graph-wal.sh" append "$CYPHER" "$PARAMS" 2>/dev/null || true
    bash "$GS" query "$CYPHER" "$PARAMS"
    ;;

  check-implements)
    SID="${1:?missing session-id}"
    bash "$GS" query "
      MATCH (impl:Session {id: \$sid})-[:IMPLEMENTS]->(ho:Session)-[:BY]->(author:Person)
      RETURN ho.id AS handoffId, ho.topic AS topic, author.name AS author,
             author.github AS authorGithub
    " "{\"sid\":\"$SID\"}"
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
      " "{\"author\":\"$AUTHOR_GH\",\"since\":\"${SINCE}T00:00:00Z\"}"
    else
      bash "$GS" query "
        MATCH (pr:PR {author: \$author})
        WHERE pr.status = 'merged'
        RETURN pr.number AS number, pr.repo AS repo, pr.title AS title,
               toString(pr.mergedAt) AS mergedAt
        ORDER BY pr.mergedAt DESC LIMIT 5
      " "{\"author\":\"$AUTHOR_GH\"}"
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
      " "{\"author\":\"$AUTHOR_NAME\",\"since\":\"${SINCE}T00:00:00Z\"}"
    else
      bash "$GS" query "
        MATCH (impl:Session)-[:IMPLEMENTS]->(ho:Session)-[:BY]->(author:Person)
        WHERE toLower(author.name) = toLower(\$author)
        MATCH (impl)-[:BY]->(implementor:Person)
        RETURN ho.topic AS handoffTopic, implementor.name AS implementedBy,
               toString(impl.wrappedAt) AS completedAt, impl.summary AS summary
        ORDER BY impl.wrappedAt DESC LIMIT 5
      " "{\"author\":\"$AUTHOR_NAME\"}"
    fi
    ;;

  wal-status)
    bash "$SCRIPT_DIR/bin/graph-wal.sh" status
    ;;

  *)
    echo '{"error":"unknown operation: '"$OP"'","operations":["mark-read","mark-done","answer-question","resolve-handoffs","set-topic","record-focus","merge-person","claim-handoff","check-implements","create-pr","update-pr","my-merged-prs","my-implemented-handoffs","wal-status","create-harvest","create-harvest-session","record-harvest-turn","complete-harvest","pause-quest","mark-dormant","expire-handoffs","auto-link-topics","migrate-dates","link-artifact-quest","derive-topics","link-sessions-quests","relate-by-title"]}'
    exit 1
    ;;

esac
