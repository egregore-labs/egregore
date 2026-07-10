#!/bin/bash
set -euo pipefail
# handoff-run.sh — atomic orchestrator for /handoff.
#
# Everything mechanical happens here, in one bash process, so the main
# session renders a single collapsed Bash tool block instead of 6+.
#
# Usage:
#   bash bin/handoff-run.sh \
#     --author <handle> \
#     --topic  "<short topic>" \
#     [--recipient <name>] \
#     [--project <name>] \
#     <<'HANDOFFEOF'
#   ...full markdown body of the handoff...
#   HANDOFFEOF
#
# The full file body is read from stdin. The script:
#   1. Computes the file path: memory/handoffs/YYYY-MM/DD-author-slug.md
#   2. Writes the file
#   3. Appends ## Repo State section (from bin/repo-state.sh) if non-empty
#   4. Prepends memory/handoffs/index.md with a new entry
#   5. Runs bin/index-handoff.sh (connected mode only) — creates Session node
#      and returns a subgraph snapshot in the result JSON
#   6. Commits + pushes memory repo (with orphan-stash dance if needed)
#   7. Publishes HTML artifact via bin/publish-artifact.sh
#   8. Sends Telegram notification via bin/notify.sh (if recipient)
#   9. Emits ONE status line and ONE JSON blob on stdout
#
# Exit codes:
#   0 on success (even if graph/publish/notify individually fail — they are
#     non-blocking and reported in the JSON).
#   1 on unrecoverable failure (file write, memory push, bad args).

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$SCRIPT_DIR/egregore.json"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  sed -n '2,30p' "$0"
  exit 0
fi

# --- Parse args ----------------------------------------------------------
AUTHOR=""
TOPIC=""
RECIPIENT=""
PROJECT=""
NO_PUSH=0
NO_NOTIFY=0
NO_PUBLISH=0
COMPOSED=""    # optional house-kit JSON — the agent-composed render spec

while [ $# -gt 0 ]; do
  case "$1" in
    --author)     AUTHOR="${2:?}";    shift 2 ;;
    --topic)      TOPIC="${2:?}";     shift 2 ;;
    --recipient)  RECIPIENT="${2:-}"; shift 2 ;;
    --project)    PROJECT="${2:-}";   shift 2 ;;
    --composed)   COMPOSED="${2:-}";  shift 2 ;;
    --no-push)    NO_PUSH=1;          shift ;;
    --no-notify)  NO_NOTIFY=1;        shift ;;
    --no-publish) NO_PUBLISH=1;       shift ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# The render source: the agent-composed house-kit JSON when supplied (rich
# component render), else the markdown handoff (deterministic floor). The
# markdown file is ALWAYS the memory record + graph index either way.
RENDER_TYPE="handoff"
RENDER_SRC=""   # resolved to $ABS_FILE after the file is written, unless composed
if [ -n "$COMPOSED" ] && [ -f "$COMPOSED" ]; then
  RENDER_TYPE="composed"
  RENDER_SRC="$COMPOSED"
fi

[ -z "$AUTHOR" ] && { echo "Missing --author" >&2; exit 1; }
[ -z "$TOPIC" ]  && { echo "Missing --topic"  >&2; exit 1; }

MODE=$(jq -r '.mode // "connected"' "$CONFIG" 2>/dev/null || echo "connected")
TODAY=$(date +%Y-%m-%d)
YYYY_MM=$(date +%Y-%m)
DD=$(date +%d)

# --- Derive slug + file path --------------------------------------------
_slugify() {
  echo "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g' \
    | sed -E 's/^-+|-+$//g' \
    | cut -c1-50
}

SLUG=$(_slugify "$TOPIC")
REL_FILE="handoffs/${YYYY_MM}/${DD}-${AUTHOR}-${SLUG}.md"
ABS_FILE="$SCRIPT_DIR/memory/${REL_FILE}"

# Collision avoidance: append -N if file already exists
N=2
while [ -e "$ABS_FILE" ]; do
  REL_FILE="handoffs/${YYYY_MM}/${DD}-${AUTHOR}-${SLUG}-${N}.md"
  ABS_FILE="$SCRIPT_DIR/memory/${REL_FILE}"
  N=$((N+1))
  [ $N -gt 99 ] && { echo "Too many collisions for $SLUG" >&2; exit 1; }
done

mkdir -p "$(dirname "$ABS_FILE")"

# --- Write the file from stdin ------------------------------------------
cat > "$ABS_FILE"

if [ ! -s "$ABS_FILE" ]; then
  echo "Empty stdin — handoff body is required" >&2
  rm -f "$ABS_FILE"
  exit 1
fi

# --- Inject **To**: line if --recipient given and body omits it -----
# index-handoff.sh parses recipients from the file body. Skills
# normally write the To line themselves, but callers that invoke
# handoff-run.sh directly often skip it. Inject after the Author
# line so the graph gets the HANDED_TO edge.
if [ -n "$RECIPIENT" ] && ! grep -qi "^\*\*[Tt]o\*\*:" "$ABS_FILE"; then
  awk -v r="$RECIPIENT" '
    !injected && /^\*\*[Aa]uthor\*\*:/ {
      print
      print "**To**: " r
      injected=1
      next
    }
    { print }
  ' "$ABS_FILE" > "$ABS_FILE.new" && mv "$ABS_FILE.new" "$ABS_FILE"
fi

# --- Append repo state ---------------------------------------------------
# --no-pr skips `gh pr list` (~400–600ms per repo). A detached PR backfill
# after the parallel phase rewrites `—` → `#N` and re-pushes memory.
REPO_STATE=$(bash "$SCRIPT_DIR/bin/repo-state.sh" --no-pr 2>/dev/null || true)
if [ -n "$REPO_STATE" ]; then
  printf '\n%s\n' "$REPO_STATE" >> "$ABS_FILE"
fi

# --- Prepend memory/handoffs/index.md -----------------------------------
INDEX="$SCRIPT_DIR/memory/handoffs/index.md"
mkdir -p "$(dirname "$INDEX")"
[ -f "$INDEX" ] || printf '# Handoffs\n\n' > "$INDEX"

if [ -n "$RECIPIENT" ]; then
  IDX_LINE="- **${TODAY}** — ${AUTHOR}: ${TOPIC} (handoff to ${RECIPIENT})"
else
  IDX_LINE="- **${TODAY}** — ${AUTHOR}: ${TOPIC} (handoff)"
fi

# Insert after the first blank line (keeping the # header intact)
awk -v line="$IDX_LINE" '
  BEGIN { inserted = 0 }
  /^$/ && !inserted { print; print line; inserted = 1; next }
  { print }
  END { if (!inserted) print line }
' "$INDEX" > "$INDEX.new" && mv "$INDEX.new" "$INDEX"

# --- Parallel stage: graph + memory + (publish → notify) ----------------
#
# Three independent branches fork here and join before we emit the result:
#   A. Graph index     — reads ABS_FILE, writes Session node to Neo4j, and
#                        returns the handoff's neighborhood as subgraph JSON.
#   B. Memory push     — commits + pushes memory repo (orphan-stash dance).
#   C. Publish+notify  — publishes HTML artifact, then (if recipient is set)
#                        sends Telegram with the artifact URL embedded.
#
# Each branch writes its result to a tmpfile. Wall-clock is max(A,B,C).
#
# The published artifact runs its own live re-query via bin/graph.sh at
# render time, so it picks up the subgraph even though Branch A may not
# have indexed the session yet by the time Branch C fires publish.

MEMORY_DIR="$SCRIPT_DIR/memory"

TMPD=$(mktemp -d -t handoff-run-XXXXXX)
trap 'rm -rf "$TMPD"' EXIT

# Extract briefing text once (used by publish and notify) so we don't
# re-awk the same file inside multiple workers.
BRIEFING_LEAD=$(awk '/^## Briefing/{found=1; next} found && /^##/{exit} found && NF{print}' "$ABS_FILE" 2>/dev/null \
  | head -2 | tr '\n' ' ' | cut -c1-200 || true)
BRIEFING_SHORT=$(awk '/^## Briefing/{found=1; next} found && /^##/{exit} found && NF{print}' "$ABS_FILE" 2>/dev/null \
  | head -3 | tr '\n' ' ' | cut -c1-280 || true)

# --- Branch A: Graph index ---
(
  if [ "$MODE" = "connected" ]; then
    GJ=$(bash "$SCRIPT_DIR/bin/index-handoff.sh" "$ABS_FILE" 2>/dev/null || echo '{}')
    SID=$(echo "$GJ" | jq -r '.sessionId // ""' 2>/dev/null || echo "")
    RES=$(echo "$GJ" | jq -r '.resolved // 0' 2>/dev/null || echo 0)
    SG=$(echo "$GJ" | jq -c '.subgraph // null' 2>/dev/null || echo "null")
    echo "$SG" > "$TMPD/subgraph"
    if [ -n "$SID" ]; then
      printf '%s\n%s\nok\n' "$SID" "$RES" > "$TMPD/graph"
    else
      printf '\n0\noffline\n' > "$TMPD/graph"
    fi
  else
    echo "null" > "$TMPD/subgraph"
    printf '\n0\nskipped\n' > "$TMPD/graph"
  fi
) &
PID_GRAPH=$!

# --- Branch D: Today's artifacts (connected mode only) ---
# The graph is the right tool for this: indexed by date + author + excluded
# tag, returns a small structured list. The filesystem would require a full
# walk of memory/knowledge/* to answer. Runs in parallel; Branch B waits on
# this before committing so the file always has the section.
(
  ARTIFACTS_JSON="[]"
  if [ "$MODE" = "connected" ]; then
    YY=$(date +%Y); MM=$(date +%-m); DD_NUM=$(date +%-d)
    RAW=$(bash "$SCRIPT_DIR/bin/graph.sh" query "
      MATCH (a:Artifact)-[:CONTRIBUTED_BY]->(p:Person {github: \$gh})
      WHERE a.created >= datetime({year: $YY, month: $MM, day: $DD_NUM})
        AND NOT 'tutorial-generated' IN coalesce(a.topics, [])
      RETURN a.title AS title, a.type AS type, a.filePath AS path
      ORDER BY a.created DESC
      LIMIT 5" "$(jq -nc --arg gh "$AUTHOR" '{gh:$gh}')" 2>/dev/null || echo '{}')
    # Response shape: {"fields":[...], "values":[[...], ...]}. Convert to
    # an array of {title, type, path} objects.
    ARTIFACTS_JSON=$(echo "$RAW" | jq -c '
      (.fields // []) as $f
      | (.values // [])
      | map(. as $row | reduce range(0; ($f | length)) as $i ({}; .[$f[$i]] = $row[$i]))
    ' 2>/dev/null || echo '[]')
    [ -z "$ARTIFACTS_JSON" ] && ARTIFACTS_JSON="[]"
  fi
  echo "$ARTIFACTS_JSON" > "$TMPD/artifacts"
) &
PID_ARTIFACTS=$!

# --- Branch B: Memory commit + push ---
(
  if [ "$NO_PUSH" = "1" ]; then
    echo "skipped (--no-push)" > "$TMPD/memory"
  else
    # Wait for Branch D (artifacts query) so the committed file has the
    # `## Session Artifacts` section. D is fast (~1s) and runs parallel
    # with Branch A; this wait doesn't extend the critical path because
    # Branch C (publish) is the bottleneck.
    wait "$PID_ARTIFACTS" 2>/dev/null || true
    if [ -s "$TMPD/artifacts" ]; then
      ART_COUNT=$(jq 'length' "$TMPD/artifacts" 2>/dev/null || echo 0)
      if [ "${ART_COUNT:-0}" -gt 0 ]; then
        {
          printf '\n## Session Artifacts\n\n'
          jq -r '.[] | "- \(.type // "Artifact"): \(.title) -> \(.path // "")"' "$TMPD/artifacts" 2>/dev/null
        } >> "$ABS_FILE"
      fi
    fi

    cd "$MEMORY_DIR"
    git add "$REL_FILE" handoffs/index.md >/dev/null 2>&1

    if [ -n "$RECIPIENT" ]; then
      MSG_COMMIT="Handoff: ${TOPIC} (to ${RECIPIENT})"
    else
      MSG_COMMIT="Handoff: ${TOPIC}"
    fi

    git commit -m "$MSG_COMMIT" >/dev/null 2>&1 || true

    STASHED=0
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
      git stash push -u -m "handoff-run pre-pull stash" >/dev/null 2>&1 && STASHED=1
    fi

    MEM_OK=0
    for i in 1 2 3; do
      if git pull --rebase origin main --quiet >/dev/null 2>&1 \
         && git push origin main --quiet >/dev/null 2>&1; then
        MEM_OK=1
        break
      fi
      sleep 1
    done

    [ "$STASHED" = "1" ] && git stash pop >/dev/null 2>&1 || true

    if [ "$MEM_OK" = "1" ]; then
      echo "ok" > "$TMPD/memory"
    else
      echo "failed" > "$TMPD/memory"
    fi
  fi
) &
PID_MEMORY=$!

# --- Branch C: Publish artifact → Notify ---
#
# Strategy: handoffs publish ONCE, through the emissary write API, using
# `render_mode: "custom"` so the server serves OUR pre-rendered HTML
# verbatim (the same egregore-artifacts handoff template /view/ has
# always used). This gives us:
#   - one artifact, one URL (no legacy + new double-publish)
#   - permanent egregore.xyz/emissary/e/<id> URL with /raw endpoint
#   - handoff design fully owned client-side (egregore-artifacts) — the
#     emissary server template is never invoked for handoffs and remains
#     completely untouched
#
# Fallback: if emissary publish fails (token missing, network, size cap,
# rendering failure), fall back to the legacy publish-artifact.sh path so
# a handoff still gets a Telegram-able URL.
(
  V1URL=""
  AURL=""
  if [ "$NO_PUBLISH" = "0" ]; then
    EMISSARY_CONFIG="$HOME/.egregore/emissary-config.json"
    EMISSARY_TOKEN=""
    if [ -f "$EMISSARY_CONFIG" ]; then
      EMISSARY_TOKEN=$(jq -r '.auth_token // empty' "$EMISSARY_CONFIG" 2>/dev/null)
    fi
    EMISSARY_API_URL="${EMISSARY_API_URL:-https://egregore-production-55f2.up.railway.app/api/v1/emissary}"

    if [ -n "$EMISSARY_TOKEN" ]; then
      # Step 1: render the handoff to HTML locally using egregore-artifacts.
      # Same renderer + template publish-artifact.sh uses today — handoffs
      # keep their familiar look.
      RENDERED_HTML="$TMPD/handoff.html"
      RENDER_OK=0
      LOCAL_CLI="$SCRIPT_DIR/packages/egregore-artifacts/bin/cli.js"
      if [ "${EGREGORE_USE_PUBLISHED:-0}" != "1" ] && [ -f "$LOCAL_CLI" ] && [ -d "$SCRIPT_DIR/packages/egregore-artifacts/node_modules/react" ]; then
        if node "$LOCAL_CLI" "$RENDER_TYPE" "${RENDER_SRC:-$ABS_FILE}" --output "$RENDERED_HTML" >/dev/null 2>&1; then
          RENDER_OK=1
        fi
      else
        if npx egregore-artifacts "$RENDER_TYPE" "${RENDER_SRC:-$ABS_FILE}" --output "$RENDERED_HTML" >/dev/null 2>&1; then
          RENDER_OK=1
        fi
      fi

      # Step 2: build the emissary payload. If rendering succeeded AND the
      # HTML fits the server's 100KB cap, send it with render_mode=custom.
      # If not, fall through to the structured-only path (server-rendered
      # via the emissary template — undesirable for handoffs but still
      # better than no URL).
      if [ "$RENDER_OK" = "1" ] && [ -f "$RENDERED_HTML" ]; then
        RENDER_SIZE=$(wc -c < "$RENDERED_HTML" | tr -d ' ')
        if [ "$RENDER_SIZE" -gt 0 ] && [ "$RENDER_SIZE" -lt 100000 ]; then
          # Author display name
          DISPLAY_NAME="$AUTHOR"
          PERSON_FILE="$SCRIPT_DIR/memory/people/${AUTHOR}.md"
          if [ -f "$PERSON_FILE" ]; then
            DISPLAY_NAME=$(head -1 "$PERSON_FILE" | sed 's/^# //')
          fi

          # addressed_to: only set if there's a recipient
          ADDRESSED_TO="[]"
          if [ -n "$RECIPIENT" ]; then
            RECIP_HANDLE=$(echo "$RECIPIENT" | tr '[:upper:]' '[:lower:]' | awk '{print $1}')
            ADDRESSED_TO=$(jq -nc --arg h "$RECIP_HANDLE" --arg d "$RECIPIENT" '[{"handle":$h,"display":$d}]')
          fi

          CLAIM=$(echo "$BRIEFING_LEAD" | cut -c1-200)

          # body.prose is schema-required non-empty even when render_mode is
          # "custom" (server validates structurally regardless of render
          # mode). The visible page is the custom HTML; prose just needs to
          # be non-empty plain text for /raw consumers and validation. Use
          # the briefing lead (which the lead/claim is already derived from).
          PROSE_TEXT="${BRIEFING_LEAD:-$TOPIC}"

          # Use --rawfile so the rendered HTML is read directly from disk
          # into a JSON-string. Faster than shell-var roundtrip and avoids
          # any quoting headaches for HTML.
          V1JSON=$(jq -nc \
            --arg topic "$TOPIC" \
            --arg claim "$CLAIM" \
            --arg summary "$CLAIM" \
            --arg prose "$PROSE_TEXT" \
            --argjson addressed "$ADDRESSED_TO" \
            --rawfile render_html "$RENDERED_HTML" \
            '{
              kind: "continuation",
              topic: $topic,
              claim: $claim,
              summary: $summary,
              body: { prose: $prose },
              audience: {
                addressed_to: $addressed,
                visible_to: "public",
                extendable_by: "anyone"
              },
              parents: [],
              render_mode: "custom",
              render_html: $render_html
            }')

          V1RESULT=$(curl -sf -X POST "$EMISSARY_API_URL/emissaries" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $EMISSARY_TOKEN" \
            -d "$V1JSON" 2>/dev/null || echo '{}')

          V1URL=$(echo "$V1RESULT" | jq -r '.url // ""' 2>/dev/null || echo "")
        fi
      fi
    fi
  fi

  # Fallback: if the emissary publish didn't produce a URL (no token, no
  # network, size cap, render failure), fire the legacy publish-artifact.sh
  # so handoffs still get a Telegram-able URL.
  if [ -z "$V1URL" ] && [ "$NO_PUBLISH" = "0" ] && [ -x "$SCRIPT_DIR/bin/publish-artifact.sh" ]; then
    AURL=$(bash "$SCRIPT_DIR/bin/publish-artifact.sh" "$RENDER_TYPE" "${RENDER_SRC:-$ABS_FILE}" \
      --title "$TOPIC" \
      --author "$AUTHOR" \
      --description "$BRIEFING_LEAD" 2>/dev/null || echo "")
  fi

  # Prefer v1 (emissary-rendered) URL when available; fall back to the
  # legacy egregore-artifacts URL only if the v1 publish failed.
  NOTIFY_URL=""
  if [ -n "$V1URL" ]; then
    echo "$V1URL" > "$TMPD/artifact"
    NOTIFY_URL="$V1URL"
  else
    echo "$AURL" > "$TMPD/artifact"
    NOTIFY_URL="$AURL"
  fi

  NS="skipped"
  if [ "$NO_NOTIFY" = "0" ]; then
    if [ -n "$NOTIFY_URL" ]; then
      MSG_NOTIFY="Handoff from ${AUTHOR}: ${TOPIC}

\"${BRIEFING_SHORT}\"

View: ${NOTIFY_URL}"
    else
      MSG_NOTIFY="Handoff from ${AUTHOR}: ${TOPIC}

\"${BRIEFING_SHORT}\""
    fi

    # Always notify. With a recipient (connected mode) → DM. Otherwise → group.
    # Self-handoffs still post to the group so they're visible on /activity
    # and in the Telegram feed — a handoff without a Telegram beat is invisible.
    if [ -n "$RECIPIENT" ] && [ "$MODE" = "connected" ]; then
      NR=$(bash "$SCRIPT_DIR/bin/notify.sh" send "$RECIPIENT" "$MSG_NOTIFY" 2>/dev/null || echo "Failed")
    else
      NR=$(bash "$SCRIPT_DIR/bin/notify.sh" group "$MSG_NOTIFY" 2>/dev/null || echo "Failed")
    fi

    if echo "$NR" | grep -qi "^Sent"; then
      NS="sent"
    elif echo "$NR" | grep -qi "^Failed"; then
      NS="failed"
    else
      NS="unknown"
    fi
  fi
  echo "$NS" > "$TMPD/notify"
) &
PID_PUBNOT=$!

# Join (never fail parent — each branch reports its own status).
# Branch D (PID_ARTIFACTS) is already awaited inside Branch B, but we wait
# again here to be safe if B skipped the wait (--no-push path).
wait "$PID_GRAPH"     2>/dev/null || true
wait "$PID_MEMORY"    2>/dev/null || true
wait "$PID_PUBNOT"    2>/dev/null || true
wait "$PID_ARTIFACTS" 2>/dev/null || true

# --- Collect results from tmpfiles --------------------------------------
SESSION_ID=""
RESOLVED=0
GRAPH_STATUS="skipped"
if [ -s "$TMPD/graph" ]; then
  SESSION_ID=$(sed -n '1p' "$TMPD/graph")
  RESOLVED=$(sed -n '2p' "$TMPD/graph")
  GRAPH_STATUS=$(sed -n '3p' "$TMPD/graph")
fi
[ -z "$RESOLVED" ] && RESOLVED=0
# Sanitize: --argjson requires a number. If RESOLVED came back as a slug or
# anything non-numeric (the index-handoff.sh output format has drifted in
# the past — defensive guard), fall back to 0 so the result file still builds.
if ! echo "$RESOLVED" | grep -qE '^[0-9]+$'; then
  RESOLVED=0
fi

SUBGRAPH_JSON=$(cat "$TMPD/subgraph" 2>/dev/null || echo "null")
[ -z "$SUBGRAPH_JSON" ] && SUBGRAPH_JSON="null"
# Sanitize: --argjson requires valid JSON. Multiple writes to the same
# tmpfile have produced concatenated values in the past (e.g. "null\n{...}"),
# which jq rejects on multi-document input. Validate; on failure, take the
# LAST non-empty line and re-validate; if still bad, fall back to null.
if ! printf '%s' "$SUBGRAPH_JSON" | jq -s 'length == 1' 2>/dev/null | grep -q '^true$'; then
  LAST_LINE=$(printf '%s\n' "$SUBGRAPH_JSON" | awk 'NF{last=$0} END{print last}')
  if printf '%s' "$LAST_LINE" | jq -e '.' >/dev/null 2>&1; then
    SUBGRAPH_JSON="$LAST_LINE"
  else
    SUBGRAPH_JSON="null"
  fi
fi

MEMORY_STATUS=$(cat "$TMPD/memory"   2>/dev/null || echo "skipped")
ARTIFACT_URL=$(cat "$TMPD/artifact"  2>/dev/null || echo "")
NOTIFY_STATUS=$(cat "$TMPD/notify"   2>/dev/null || echo "skipped")
ARTIFACTS_ARR=$(cat "$TMPD/artifacts" 2>/dev/null || echo "[]")
[ -z "$ARTIFACTS_ARR" ] && ARTIFACTS_ARR="[]"

# --- Detached PR-number backfill ----------------------------------------
# repo-state.sh was called with --no-pr for speed; now fire the backfill in
# the background so PR columns get populated without blocking this script.
# Reparented to init via `( cmd & ) >/dev/null 2>&1` — survives our exit.
if [ "$MEMORY_STATUS" = "ok" ] && grep -q '^## Repo State' "$ABS_FILE" 2>/dev/null; then
  ( bash "$SCRIPT_DIR/bin/handoff-pr-backfill.sh" "$ABS_FILE" "$TOPIC" >/dev/null 2>&1 & ) >/dev/null 2>&1
fi

# --- Emit minimal stdout, stash structured data in a tmpfile ------------
#
# The Bash tool block shows stdout verbatim and collapses after ~3 lines.
# We keep stdout to exactly one compact status line so the block is
# visually quiet. Full structured data goes to a well-known tmpfile that
# the caller (skill) reads to render the rich card.
STATUS_BITS=("saved")
[ "$GRAPH_STATUS"  = "ok" ]    && STATUS_BITS+=("graphed")
[ "$MEMORY_STATUS" = "ok" ]    && STATUS_BITS+=("pushed")
if [ "$NOTIFY_STATUS" = "sent" ]; then
  if [ -n "$RECIPIENT" ]; then
    STATUS_BITS+=("${RECIPIENT} notified")
  else
    STATUS_BITS+=("group notified")
  fi
elif [ "$NOTIFY_STATUS" = "unknown" ] && [ -n "$RECIPIENT" ]; then
  STATUS_BITS+=("${RECIPIENT} relayed to group")
fi
[ -n "$ARTIFACT_URL" ]         && STATUS_BITS+=("published")

STATUS_LINE=""
for bit in "${STATUS_BITS[@]}"; do
  if [ -z "$STATUS_LINE" ]; then
    STATUS_LINE="$bit"
  else
    STATUS_LINE="${STATUS_LINE} · ${bit}"
  fi
done

# Stash structured result for the caller
RESULT_FILE="${TMPDIR:-/tmp}/handoff-run-result.json"
jq -cn \
  --arg mode "$MODE" \
  --arg file "$REL_FILE" \
  --arg absFile "$ABS_FILE" \
  --arg sessionId "$SESSION_ID" \
  --argjson resolved "${RESOLVED:-0}" \
  --arg graphStatus "$GRAPH_STATUS" \
  --arg memoryStatus "$MEMORY_STATUS" \
  --arg notifyStatus "$NOTIFY_STATUS" \
  --arg artifactUrl "$ARTIFACT_URL" \
  --arg recipient "$RECIPIENT" \
  --arg topic "$TOPIC" \
  --arg author "$AUTHOR" \
  --argjson subgraph "$SUBGRAPH_JSON" \
  --argjson artifacts "$ARTIFACTS_ARR" \
  '{
    mode:$mode,
    file:$file,
    absFile:$absFile,
    sessionId:$sessionId,
    resolved:$resolved,
    graphStatus:$graphStatus,
    memoryStatus:$memoryStatus,
    notifyStatus:$notifyStatus,
    artifactUrl:$artifactUrl,
    recipient:$recipient,
    topic:$topic,
    author:$author,
    subgraph:$subgraph,
    artifacts:$artifacts
  }' > "$RESULT_FILE"

# One clean line for the Bash tool block.
# The caller reads structured data from $TMPDIR/handoff-run-result.json.
echo "⇌ ${STATUS_LINE}"
