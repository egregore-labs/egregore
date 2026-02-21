#!/bin/bash
# Named graph operations for eval — clean interface over raw Cypher.
# Keeps implementation details out of the TUI.
#
# Usage: bash bin/eval-op.sh <operation> [args...]
#
# Operations:
#   create-run <runId> <pipelineId> <config> <input> <outputPath> <totalTokens> <cost> <latency>
#   create-match <matchId> <pipelineId> <configA> <configB> <input> <dimension> <winner> <confidence> <reasoning> <judgeModel>
#   create-report <reportId> <pipelineId> <filePath> <configsJson> <eloJson> <bestConfig> <bestEfficiency> <matchCount>
#   get-runs <pipelineId>
#   get-matches <pipelineId>
#   get-latest-report <pipelineId>

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GS="$SCRIPT_DIR/bin/graph.sh"

OP="${1:-}"
shift 2>/dev/null

case "$OP" in

  create-run)
    RUN_ID="$1"
    PIPELINE_ID="$2"
    CONFIG="$3"
    INPUT="$4"
    OUTPUT_PATH="$5"
    TOTAL_TOKENS="$6"
    COST="$7"
    LATENCY="$8"
    [ -z "$RUN_ID" ] && echo '{"error":"missing runId"}' && exit 1
    [ -z "$PIPELINE_ID" ] && echo '{"error":"missing pipelineId"}' && exit 1
    PARAMS=$(jq -n \
      --arg runId "$RUN_ID" \
      --arg pipelineId "$PIPELINE_ID" \
      --arg config "$CONFIG" \
      --arg input "$INPUT" \
      --arg outputPath "$OUTPUT_PATH" \
      --arg totalTokens "$TOTAL_TOKENS" \
      --arg cost "$COST" \
      --arg latency "$LATENCY" \
      '{runId: $runId, pipelineId: $pipelineId, config: $config, input: $input, outputPath: $outputPath, totalTokens: $totalTokens, cost: $cost, latency: $latency}')
    bash "$GS" query "
      CREATE (er:EvalRun {
        id: \$runId,
        pipelineId: \$pipelineId,
        config: \$config,
        input: \$input,
        runDate: datetime(),
        outputPath: \$outputPath,
        totalTokens: toInteger(\$totalTokens),
        estimatedCostUsd: toFloat(\$cost),
        latencyMs: toInteger(\$latency)
      })
      RETURN er.id AS id, er.config AS config, er.runDate AS runDate
    " "$PARAMS" 2>/dev/null
    ;;

  create-match)
    MATCH_ID="$1"
    PIPELINE_ID="$2"
    CONFIG_A="$3"
    CONFIG_B="$4"
    INPUT="$5"
    DIMENSION="$6"
    WINNER="$7"
    CONFIDENCE="$8"
    REASONING="$9"
    JUDGE_MODEL="${10}"
    [ -z "$MATCH_ID" ] && echo '{"error":"missing matchId"}' && exit 1
    [ -z "$PIPELINE_ID" ] && echo '{"error":"missing pipelineId"}' && exit 1
    PARAMS=$(jq -n \
      --arg matchId "$MATCH_ID" \
      --arg pipelineId "$PIPELINE_ID" \
      --arg configA "$CONFIG_A" \
      --arg configB "$CONFIG_B" \
      --arg input "$INPUT" \
      --arg dimension "$DIMENSION" \
      --arg winner "$WINNER" \
      --arg confidence "$CONFIDENCE" \
      --arg judgeModel "$JUDGE_MODEL" \
      --arg reasoning "$REASONING" \
      '{matchId: $matchId, pipelineId: $pipelineId, configA: $configA, configB: $configB, input: $input, dimension: $dimension, winner: $winner, confidence: $confidence, judgeModel: $judgeModel, reasoning: $reasoning}')
    bash "$GS" query "
      CREATE (em:EvalMatch {
        id: \$matchId,
        pipelineId: \$pipelineId,
        configA: \$configA,
        configB: \$configB,
        input: \$input,
        dimension: \$dimension,
        winner: \$winner,
        judgeConfidence: \$confidence,
        judgeModel: \$judgeModel,
        judgeReasoning: \$reasoning,
        matchDate: datetime()
      })
      RETURN em.id AS id, em.winner AS winner, em.dimension AS dimension
    " "$PARAMS" 2>/dev/null
    ;;

  create-report)
    REPORT_ID="$1"
    PIPELINE_ID="$2"
    FILE_PATH="$3"
    CONFIGS_JSON="$4"
    ELO_JSON="$5"
    BEST_CONFIG="$6"
    BEST_EFFICIENCY="$7"
    MATCH_COUNT="$8"
    [ -z "$REPORT_ID" ] && echo '{"error":"missing reportId"}' && exit 1
    [ -z "$PIPELINE_ID" ] && echo '{"error":"missing pipelineId"}' && exit 1
    PARAMS=$(jq -n \
      --arg reportId "$REPORT_ID" \
      --arg pipelineId "$PIPELINE_ID" \
      --arg filePath "$FILE_PATH" \
      --arg configs "$CONFIGS_JSON" \
      --arg elo "$ELO_JSON" \
      --arg bestConfig "$BEST_CONFIG" \
      --arg bestEfficiency "$BEST_EFFICIENCY" \
      --arg matchCount "$MATCH_COUNT" \
      --arg author "${EGREGORE_USER:-unknown}" \
      '{reportId: $reportId, pipelineId: $pipelineId, filePath: $filePath, configs: $configs, elo: $elo, bestConfig: $bestConfig, bestEfficiency: $bestEfficiency, matchCount: $matchCount, author: $author}')
    bash "$GS" query "
      CREATE (rep:EvalReport {
        id: \$reportId,
        pipelineId: \$pipelineId,
        reportDate: datetime(),
        filePath: \$filePath,
        configs: \$configs,
        eloRatings: \$elo,
        bestConfig: \$bestConfig,
        bestEloPerDollar: \$bestEfficiency,
        matchCount: toInteger(\$matchCount)
      })
      WITH rep
      OPTIONAL MATCH (p:Person {name: \$author})
      FOREACH (_ IN CASE WHEN p IS NOT NULL THEN [1] ELSE [] END |
        MERGE (rep)-[:CONTRIBUTED_BY]->(p)
      )
      RETURN rep.id AS id, rep.bestConfig AS bestConfig
    " "$PARAMS" 2>/dev/null
    ;;

  get-runs)
    PIPELINE_ID="$1"
    [ -z "$PIPELINE_ID" ] && echo '{"error":"missing pipelineId"}' && exit 1
    PARAMS=$(jq -n --arg pipelineId "$PIPELINE_ID" '{pipelineId: $pipelineId}')
    bash "$GS" query "
      MATCH (er:EvalRun {pipelineId: \$pipelineId})
      RETURN er.id AS id, er.config AS config, er.input AS input,
             er.runDate AS runDate, er.outputPath AS outputPath,
             er.totalTokens AS totalTokens, er.estimatedCostUsd AS cost,
             er.latencyMs AS latency
      ORDER BY er.runDate DESC
      LIMIT 100
    " "$PARAMS" 2>/dev/null
    ;;

  get-matches)
    PIPELINE_ID="$1"
    [ -z "$PIPELINE_ID" ] && echo '{"error":"missing pipelineId"}' && exit 1
    PARAMS=$(jq -n --arg pipelineId "$PIPELINE_ID" '{pipelineId: $pipelineId}')
    bash "$GS" query "
      MATCH (em:EvalMatch {pipelineId: \$pipelineId})
      RETURN em.id AS id, em.configA AS configA, em.configB AS configB,
             em.input AS input, em.dimension AS dimension,
             em.winner AS winner, em.judgeConfidence AS confidence,
             em.judgeModel AS judgeModel, em.judgeReasoning AS reasoning,
             em.matchDate AS matchDate
      ORDER BY em.matchDate DESC
      LIMIT 500
    " "$PARAMS" 2>/dev/null
    ;;

  get-latest-report)
    PIPELINE_ID="$1"
    [ -z "$PIPELINE_ID" ] && echo '{"error":"missing pipelineId"}' && exit 1
    PARAMS=$(jq -n --arg pipelineId "$PIPELINE_ID" '{pipelineId: $pipelineId}')
    bash "$GS" query "
      MATCH (rep:EvalReport {pipelineId: \$pipelineId})
      RETURN rep.id AS id, rep.reportDate AS reportDate,
             rep.filePath AS filePath, rep.configs AS configs,
             rep.eloRatings AS eloRatings, rep.bestConfig AS bestConfig,
             rep.bestEloPerDollar AS bestEloPerDollar,
             rep.matchCount AS matchCount
      ORDER BY rep.reportDate DESC
      LIMIT 1
    " "$PARAMS" 2>/dev/null
    ;;

  *)
    echo '{"error":"unknown operation: '"$OP"'","operations":["create-run","create-match","create-report","get-runs","get-matches","get-latest-report"]}'
    exit 1
    ;;

esac
