#!/usr/bin/env bash
set -euo pipefail

# Graph maintenance — scan for issues, fix safe ones, report health.
# Usage: bash bin/graph-maintenance.sh <mode>
#
# Modes:
#   scan      Detect issues (read-only). Returns JSON with categorized findings.
#   fix       Run auto-fixable repairs. Returns JSON with fix results.
#   summary   Health metrics only (node/edge counts, orphan rate).
#
# Note: All queries use labeled node patterns (API requires org isolation).

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  echo "Usage: graph-maintenance.sh <mode> [args...]"
  echo ""
  echo "Graph maintenance — scan for issues, fix safe ones, report health."
  echo ""
  echo "Modes:"
  echo "  scan                  Detect issues (read-only, default)"
  echo "  fix <pattern> [args]  Run auto-fixable repairs"
  echo "  summary               Health metrics only (node/edge counts)"
  echo ""
  echo "Fix patterns: stale-handoffs, quest-decay, date-type-mix,"
  echo "  disconnected-artifacts, duplicate-persons"
  exit 0
fi

GS="$SCRIPT_DIR/bin/graph.sh"
GB="$SCRIPT_DIR/bin/graph-batch.sh"
GO="$SCRIPT_DIR/bin/graph-op.sh"

MODE="${1:-scan}"

case "$MODE" in

  scan)
    # 7 detection patterns + 4 health metric queries = 11 queries (under 20 batch limit)
    # All use labeled patterns for API org isolation compliance.
    RESULT=$(bash "$GB" '[
      {"statement": "MATCH (s:Session)-[:HANDED_TO]->(:Person) WHERE s.handoffStatus = \"pending\" AND s.date < date() - duration(\"P30D\") RETURN s.id AS id, s.topic AS topic, toString(s.date) AS date", "parameters": {}},

      {"statement": "MATCH (q:Quest {status: \"active\"}) OPTIONAL MATCH (a:Artifact)-[:PART_OF]->(q) WITH q, max(a.created) AS lastArtifact WHERE lastArtifact IS NULL OR lastArtifact < date() - duration(\"P30D\") RETURN q.id AS id, q.title AS title, toString(lastArtifact) AS lastArtifact", "parameters": {}},

      {"statement": "MATCH (s:Session) WHERE toString(s.date) CONTAINS \"T\" RETURN count(s) AS count", "parameters": {}},

      {"statement": "MATCH (a:Artifact) WHERE toString(a.created) CONTAINS \"T\" RETURN count(a) AS count", "parameters": {}},

      {"statement": "MATCH (a:Artifact) WHERE NOT (a)-[:PART_OF]->(:Quest) RETURN a.id AS id, a.title AS title, a.type AS type LIMIT 20", "parameters": {}},

      {"statement": "MATCH (a:Artifact) WHERE a.filePath IS NULL RETURN a.id AS id, a.title AS title, a.type AS type LIMIT 20", "parameters": {}},

      {"statement": "MATCH (s:Session) WHERE NOT (s)-[:BY]->(:Person) AND NOT (s)-[:HANDED_TO]->(:Person) RETURN s.id AS id, s.topic AS topic, toString(s.date) AS date LIMIT 20", "parameters": {}},

      {"statement": "MATCH (p:Person) WITH toLower(p.name) AS lname, collect(p) AS nodes WHERE size(nodes) > 1 RETURN lname AS name, size(nodes) AS count, [n IN nodes | n.name] AS variants LIMIT 10", "parameters": {}},

      {"statement": "MATCH (s:Session) RETURN count(s) AS count", "parameters": {}},
      {"statement": "MATCH (a:Artifact) RETURN count(a) AS count", "parameters": {}},
      {"statement": "MATCH (q:Quest) RETURN count(q) AS count", "parameters": {}}
    ]' 2>/dev/null) || { echo '{"error":"batch query failed"}'; exit 1; }

    # Parse results into structured JSON
    # Results order: 0=stale_handoffs, 1=quest_decay, 2=date_mix_sessions, 3=date_mix_artifacts,
    #               4=disconnected_artifacts, 5=ghost_artifacts, 6=orphaned_sessions,
    #               7=duplicate_persons, 8=session_count, 9=artifact_count, 10=quest_count
    echo "$RESULT" | jq '{
      findings: {
        stale_handoffs:         { action: "auto-fix", items: (.results[0].values // []) | map({id: .[0], topic: .[1], date: .[2]}) },
        quest_decay:            { action: "auto-fix", items: (.results[1].values // []) | map({id: .[0], title: .[1], lastArtifact: .[2]}) },
        date_type_mix:          { action: "auto-fix", counts: { sessions: ((.results[2].values[0][0]) // 0), artifacts: ((.results[3].values[0][0]) // 0) } },
        disconnected_artifacts: { action: "suggest",  items: (.results[4].values // []) | map({id: .[0], title: .[1], type: .[2]}) },
        ghost_artifacts:        { action: "flag",     items: (.results[5].values // []) | map({id: .[0], title: .[1], type: .[2]}) },
        orphaned_sessions:      { action: "flag",     items: (.results[6].values // []) | map({id: .[0], topic: .[1], date: .[2]}) },
        duplicate_persons:      { action: "suggest",  items: (.results[7].values // []) | map({name: .[0], count: .[1], variants: .[2]}) }
      },
      health: {
        sessions:  ((.results[8].values[0][0]) // 0),
        artifacts: ((.results[9].values[0][0]) // 0),
        quests:    ((.results[10].values[0][0]) // 0)
      }
    }'
    ;;

  fix)
    PATTERN="${2:?missing pattern name (stale-handoffs|quest-decay|date-type-mix|disconnected-artifacts|duplicate-persons)}"
    shift 2

    case "$PATTERN" in
      stale-handoffs)
        # Get current user for resolve-handoffs
        ME=$(git -C "$SCRIPT_DIR" config user.name 2>/dev/null | awk '{print tolower($1)}' || echo "unknown")
        bash "$GO" resolve-handoffs "$ME"
        ;;
      quest-decay)
        QID="${1:?missing quest-id}"
        bash "$GO" pause-quest "$QID"
        ;;
      date-type-mix)
        # Fix both Session.date and Artifact.created
        S_RESULT=$(bash "$GO" migrate-dates "Session" "date" 2>/dev/null || echo '{"error":"session migration failed"}')
        A_RESULT=$(bash "$GO" migrate-dates "Artifact" "created" 2>/dev/null || echo '{"error":"artifact migration failed"}')
        jq -n --argjson sessions "$S_RESULT" --argjson artifacts "$A_RESULT" \
          '{sessions: $sessions, artifacts: $artifacts}'
        ;;
      disconnected-artifacts)
        AID="${1:?missing artifact-id}"
        QID="${2:?missing quest-id}"
        bash "$GO" link-artifact-quest "$AID" "$QID"
        ;;
      duplicate-persons)
        KEEP="${1:?missing keep-name}"
        REMOVE="${2:?missing remove-name}"
        bash "$GO" merge-person "$KEEP" "$REMOVE"
        ;;
      *)
        echo '{"error":"unknown pattern: '"$PATTERN"'","patterns":["stale-handoffs","quest-decay","date-type-mix","disconnected-artifacts","duplicate-persons"]}'
        exit 1
        ;;
    esac
    ;;

  summary)
    bash "$GB" '[
      {"statement": "MATCH (s:Session) RETURN count(s) AS count", "parameters": {}},
      {"statement": "MATCH (a:Artifact) RETURN count(a) AS count", "parameters": {}},
      {"statement": "MATCH (q:Quest) RETURN count(q) AS count", "parameters": {}},
      {"statement": "MATCH (p:Person) RETURN count(p) AS count", "parameters": {}},
      {"statement": "MATCH (s:Session)-[r]-(:Person) RETURN count(r) AS count", "parameters": {}},
      {"statement": "MATCH (:Artifact)-[r]-(:Quest) RETURN count(r) AS count", "parameters": {}}
    ]' 2>/dev/null | jq '{
      health: {
        sessions:  ((.results[0].values[0][0]) // 0),
        artifacts: ((.results[1].values[0][0]) // 0),
        quests:    ((.results[2].values[0][0]) // 0),
        persons:   ((.results[3].values[0][0]) // 0),
        session_person_edges: ((.results[4].values[0][0]) // 0),
        artifact_quest_edges: ((.results[5].values[0][0]) // 0)
      }
    }'
    ;;

  *)
    echo '{"error":"unknown mode: '"$MODE"'","modes":["scan","fix","summary"]}'
    exit 1
    ;;

esac
