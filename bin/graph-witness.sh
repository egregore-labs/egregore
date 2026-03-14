#!/bin/bash
set -euo pipefail

# Graph Witness — read-only quality evaluator for the knowledge graph.
# Measures structural health without modifying anything.
# Designed to run before and after spirit cycles to measure delta.
#
# Usage: bash bin/graph-witness.sh [mode]
#
# Modes:
#   report    Full quality report (default). Returns JSON with all metrics.
#   baseline  Save current metrics as baseline for delta comparison.
#   delta     Compare current metrics against saved baseline.

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GS="$SCRIPT_DIR/bin/graph.sh"
GB="$SCRIPT_DIR/bin/graph-batch.sh"
BASELINE_FILE="$SCRIPT_DIR/.witness-baseline.json"

MODE="${1:-report}"

# ── Metric queries ──────────────────────────────────────────────────────
# All read-only, all use labeled patterns for API compliance.

run_metrics() {
  bash "$GB" '[
    {"statement": "MATCH (a:Artifact) RETURN count(a) AS total", "parameters": {}},

    {"statement": "MATCH (a:Artifact) WHERE NOT (a)-[:PART_OF]->(:Quest) AND NOT (a)-[:RELATES_TO]-(:Artifact) AND NOT (a)-[:BUILDS_ON]-(:Artifact) AND NOT (a)<-[:BUILDS_ON]-(:Artifact) RETURN count(a) AS isolated", "parameters": {}},

    {"statement": "MATCH (s:Session) RETURN count(s) AS total", "parameters": {}},

    {"statement": "MATCH (s:Session) WHERE NOT (s)-[:BY]->(:Person) AND NOT (s)-[:HANDED_TO]->(:Person) AND NOT (s)-[:ADVANCED]->(:Quest) RETURN count(s) AS isolated", "parameters": {}},

    {"statement": "MATCH (q:Quest) RETURN count(q) AS total", "parameters": {}},

    {"statement": "MATCH (q:Quest) WHERE NOT (q)<-[:PART_OF]-(:Artifact) AND NOT (q)<-[:ADVANCED]-(:Session) RETURN count(q) AS isolated", "parameters": {}},

    {"statement": "MATCH (a1:Artifact)-[:RELATES_TO]-(a2:Artifact) RETURN count(DISTINCT a1) AS connected_artifacts", "parameters": {}},

    {"statement": "MATCH (a:Artifact)-[r:RELATES_TO]-(a2:Artifact) RETURN count(r) AS relates_to", "parameters": {}},
    {"statement": "MATCH (a:Artifact)-[r:BUILDS_ON]->(a2:Artifact) RETURN count(r) AS builds_on", "parameters": {}},
    {"statement": "MATCH (a:Artifact)-[r:PART_OF]->(q:Quest) RETURN count(r) AS part_of", "parameters": {}},
    {"statement": "MATCH (s:Session)-[r:ADVANCED]->(q:Quest) RETURN count(r) AS advanced", "parameters": {}},
    {"statement": "MATCH (s:Session)-[r:BY]->(p:Person) RETURN count(r) AS by_edges", "parameters": {}},

    {"statement": "MATCH (a:Artifact)-[:PART_OF]->(q:Quest) WITH q, count(a) AS artifact_count RETURN avg(artifact_count) AS avg_artifacts_per_quest, max(artifact_count) AS max, min(artifact_count) AS min", "parameters": {}},

    {"statement": "MATCH (a:Artifact) WHERE a.topics IS NOT NULL AND size(a.topics) > 0 RETURN count(a) AS with_topics", "parameters": {}},

    {"statement": "MATCH (a:Artifact)-[:RELATES_TO]-(a2:Artifact) WITH a, count(DISTINCT a2) AS neighbors RETURN avg(neighbors) AS avg_neighbors, max(neighbors) AS max_neighbors, percentileDisc(neighbors, 0.5) AS median_neighbors", "parameters": {}},

    {"statement": "MATCH (p:Person)<-[:BY]-(s:Session) WITH p, count(s) AS sessions MATCH (p)<-[:CONTRIBUTED_BY]-(a:Artifact) WITH p, sessions, count(a) AS artifacts RETURN p.name AS person, sessions, artifacts", "parameters": {}}
  ]' 2>/dev/null
}

case "$MODE" in

  report)
    RAW=$(run_metrics) || { echo '{"error":"metric queries failed"}'; exit 1; }

    echo "$RAW" | jq '{
      timestamp: (now | todate),
      metrics: {
        isolation: {
          artifact_total:    (.results[0].values[0][0] // 0),
          artifact_isolated: (.results[1].values[0][0] // 0),
          artifact_isolation_rate: (if (.results[0].values[0][0] // 0) > 0 then ((.results[1].values[0][0] // 0) * 100.0 / (.results[0].values[0][0])) | . * 100 | round / 100 else 0 end),
          session_total:     (.results[2].values[0][0] // 0),
          session_isolated:  (.results[3].values[0][0] // 0),
          session_isolation_rate: (if (.results[2].values[0][0] // 0) > 0 then ((.results[3].values[0][0] // 0) * 100.0 / (.results[2].values[0][0])) | . * 100 | round / 100 else 0 end),
          quest_total:       (.results[4].values[0][0] // 0),
          quest_isolated:    (.results[5].values[0][0] // 0)
        },
        connectivity: {
          artifacts_in_relates_to: (.results[6].values[0][0] // 0),
          relates_to_edges:  (.results[7].values[0][0] // 0),
          builds_on_edges:   (.results[8].values[0][0] // 0),
          part_of_edges:     (.results[9].values[0][0] // 0),
          advanced_edges:    (.results[10].values[0][0] // 0),
          by_edges:          (.results[11].values[0][0] // 0)
        },
        clustering: {
          avg_artifacts_per_quest: (.results[12].values[0][0] // 0),
          max_artifacts_per_quest: (.results[12].values[0][1] // 0),
          min_artifacts_per_quest: (.results[12].values[0][2] // 0)
        },
        topic_coverage: {
          artifacts_with_topics: (.results[13].values[0][0] // 0),
          topic_coverage_rate: (if (.results[0].values[0][0] // 0) > 0 then ((.results[13].values[0][0] // 0) * 100.0 / (.results[0].values[0][0])) | . * 100 | round / 100 else 0 end)
        },
        neighborhood: {
          avg_relates_to_neighbors: (.results[14].values[0][0] // 0),
          max_relates_to_neighbors: (.results[14].values[0][1] // 0),
          median_relates_to_neighbors: (.results[14].values[0][2] // 0)
        },
        contributors: (.results[15].values // [] | map({name: .[0], sessions: .[1], artifacts: .[2]}))
      }
    }'
    ;;

  baseline)
    RAW=$(run_metrics) || { echo '{"error":"metric queries failed"}'; exit 1; }

    echo "$RAW" | jq '{
      timestamp: (now | todate),
      artifact_total:    (.results[0].values[0][0] // 0),
      artifact_isolated: (.results[1].values[0][0] // 0),
      session_total:     (.results[2].values[0][0] // 0),
      session_isolated:  (.results[3].values[0][0] // 0),
      quest_total:       (.results[4].values[0][0] // 0),
      quest_isolated:    (.results[5].values[0][0] // 0),
      relates_to_edges:  (.results[7].values[0][0] // 0),
      builds_on_edges:   (.results[8].values[0][0] // 0),
      part_of_edges:     (.results[9].values[0][0] // 0),
      advanced_edges:    (.results[10].values[0][0] // 0),
      artifacts_with_topics: (.results[13].values[0][0] // 0)
    }' > "$BASELINE_FILE"

    echo "Baseline saved to $BASELINE_FILE"
    cat "$BASELINE_FILE"
    ;;

  delta)
    if [ ! -f "$BASELINE_FILE" ]; then
      echo '{"error":"no baseline found. Run: bash bin/graph-witness.sh baseline"}'
      exit 1
    fi

    BASELINE=$(cat "$BASELINE_FILE")
    RAW=$(run_metrics) || { echo '{"error":"metric queries failed"}'; exit 1; }

    CURRENT=$(echo "$RAW" | jq '{
      artifact_total:    (.results[0].values[0][0] // 0),
      artifact_isolated: (.results[1].values[0][0] // 0),
      session_total:     (.results[2].values[0][0] // 0),
      session_isolated:  (.results[3].values[0][0] // 0),
      quest_total:       (.results[4].values[0][0] // 0),
      quest_isolated:    (.results[5].values[0][0] // 0),
      relates_to_edges:  (.results[7].values[0][0] // 0),
      builds_on_edges:   (.results[8].values[0][0] // 0),
      part_of_edges:     (.results[9].values[0][0] // 0),
      advanced_edges:    (.results[10].values[0][0] // 0),
      artifacts_with_topics: (.results[13].values[0][0] // 0)
    }')

    jq -n --argjson baseline "$BASELINE" --argjson current "$CURRENT" '{
      baseline_timestamp: $baseline.timestamp,
      current_timestamp: (now | todate),
      delta: {
        artifact_isolated:    ($current.artifact_isolated - $baseline.artifact_isolated),
        session_isolated:     ($current.session_isolated - $baseline.session_isolated),
        quest_isolated:       ($current.quest_isolated - $baseline.quest_isolated),
        relates_to_edges:     ($current.relates_to_edges - $baseline.relates_to_edges),
        builds_on_edges:      ($current.builds_on_edges - $baseline.builds_on_edges),
        part_of_edges:        ($current.part_of_edges - $baseline.part_of_edges),
        advanced_edges:       ($current.advanced_edges - $baseline.advanced_edges),
        artifacts_with_topics: ($current.artifacts_with_topics - $baseline.artifacts_with_topics)
      },
      direction: {
        isolation: (if ($current.artifact_isolated < $baseline.artifact_isolated) then "improving" elif ($current.artifact_isolated == $baseline.artifact_isolated) then "stable" else "degrading" end),
        connectivity: (if ($current.relates_to_edges > $baseline.relates_to_edges) then "improving" elif ($current.relates_to_edges == $baseline.relates_to_edges) then "stable" else "degrading" end),
        coverage: (if ($current.artifacts_with_topics > $baseline.artifacts_with_topics) then "improving" elif ($current.artifacts_with_topics == $baseline.artifacts_with_topics) then "stable" else "degrading" end)
      }
    }'
    ;;

  *)
    echo '{"error":"unknown mode: '"$MODE"'","modes":["report","baseline","delta"]}'
    exit 1
    ;;

esac
