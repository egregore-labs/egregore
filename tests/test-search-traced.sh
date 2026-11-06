#!/usr/bin/env bash
# bin/search.sh wraps Runtime find/open in _traced. Untraced calls (Codex, Pi,
# Prime, or Claude without the traces beta) must pass output and exit status
# through unchanged and post nothing. Traced calls must post one OTLP/JSON span
# under the inherited TRACEPARENT carrying bounded, content-free attributes.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

# Load _now_ms and _traced without running search.sh's dispatcher.
SCRIPT_DIR="$ROOT"
eval "$(sed -n '/^_now_ms() {/,/^}/p' "$ROOT/bin/search.sh")"
eval "$(sed -n '/^_traced() {/,/^}/p' "$ROOT/bin/search.sh")"
type _traced >/dev/null 2>&1 || { echo "FAIL: _traced is not defined in bin/search.sh" >&2; exit 1; }
grep -q '_traced egregore.search.find FIND_ARGS _runtime find' "$ROOT/bin/search.sh" || { echo "FAIL: find does not run through _traced" >&2; exit 1; }
grep -q '_traced egregore.search.open OPEN_ARGS _runtime open' "$ROOT/bin/search.sh" || { echo "FAIL: open does not run through _traced" >&2; exit 1; }

unset TRACEPARENT OTEL_EXPORTER_OTLP_PROTOCOL OTEL_EXPORTER_OTLP_TRACES_PROTOCOL \
  EGREGORE_OTLP_TRACES_ENDPOINT OTEL_EXPORTER_OTLP_TRACES_ENDPOINT OTEL_LOG_TOOL_DETAILS \
  BETA_TRACING_ENDPOINT OTEL_RESOURCE_ATTRIBUTES OTEL_EXPORTER_OTLP_HEADERS

TMP="$(mktemp -d "${TMPDIR:-/tmp}/egregore-traced-test.XXXXXX")"
SINK_PID=""
trap '[ -n "$SINK_PID" ] && kill "$SINK_PID" 2>/dev/null; rm -rf "$TMP"' EXIT
SPANS="$TMP/spans.jsonl"
: > "$SPANS"

# A receiver that appends every POST body as one line.
python3 - "$SPANS" "$TMP/port" <<'PY' &
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
out, portfile = sys.argv[1], sys.argv[2]
class H(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        with open(out, "a") as f:
            f.write(json.dumps({"path": self.path, "body": json.loads(body)}) + "\n")
        self.send_response(200); self.send_header("Content-Length", "2"); self.end_headers(); self.wfile.write(b"{}")
srv = HTTPServer(("127.0.0.1", 0), H)
open(portfile, "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY
SINK_PID=$!
disown "$SINK_PID" 2>/dev/null || true  # no job-control report when the trap kills it
for _ in $(seq 1 50); do [ -s "$TMP/port" ] && break; sleep 0.1; done
PORT="$(cat "$TMP/port" 2>/dev/null || true)"
[ -n "$PORT" ] || { echo "FAIL: receiver did not start" >&2; exit 1; }
export OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:$PORT"

span_count() { wc -l < "$SPANS" | tr -d ' '; }
wait_spans() { for _ in $(seq 1 50); do [ "$(span_count)" -ge "$1" ] && return 0; sleep 0.1; done; return 1; }
last_span() {
  tail -n 1 "$SPANS" | python3 -c '
import json, sys
r = json.load(sys.stdin)["body"]["resourceSpans"][0]
s = r["scopeSpans"][0]["spans"][0]
attrs = {a["key"]: str(list(a["value"].values())[0]) for a in s["attributes"]}
resource = {a["key"]: str(list(a["value"].values())[0]) for a in r["resource"]["attributes"]}
print(json.dumps({"trace": s["traceId"], "parent": s["parentSpanId"], "name": s["name"],
                  "status": s["status"]["code"], "attrs": attrs, "resource": resource}))'
}
attr() { printf '%s' "$1" | python3 -c "import json,sys; print(json.load(sys.stdin)['attrs'].get('$2', '<absent>'))"; }
field() { printf '%s' "$1" | python3 -c "import json,sys; print(json.load(sys.stdin)['$2'])"; }

TRACE=0af7651916cd43dd8448eb211c80319c
PARENT=b7ad6b7169203331

echo "search.sh _traced"

# 1. Untraced: identical passthrough, exit status preserved, nothing posted.
ARGS=("hello" --kind keyword)
out="$(_traced egregore.search.find ARGS printf '1. a\n2. b\n')"; rc=$?
[ "$out" = "$(printf '1. a\n2. b\n')" ] && [ "$rc" -eq 0 ] && pass "untraced find passes output through" || fail "untraced find altered output or status (rc=$rc)"
_traced egregore.search.open ARGS bash -c 'echo partial; exit 3' >/dev/null; rc=$?
[ "$rc" -eq 3 ] && pass "untraced call preserves a non-zero exit status" || fail "untraced exit status was $rc, expected 3"
sleep 0.3
[ "$(span_count)" -eq 0 ] && pass "untraced calls post no span" || fail "an untraced call posted a span"

# 2. Traced: output and status still pass through; one span lands under the parent.
export TRACEPARENT="00-$TRACE-$PARENT-01"
ARGS=("hello world" --kind hybrid --recent-days 30 --prefix memory/private --context-packet --episode ep_secret_reference)
out="$(_traced egregore.search.find ARGS bash -c 'printf "1. a\n2. b\nNote: 7 eligible documents were stale\n"; exit 0')"; rc=$?
[ "$rc" -eq 0 ] && [ "$(printf '%s\n' "$out" | head -n1)" = "1. a" ] && pass "traced find passes output through" || fail "traced find altered output or status (rc=$rc)"
wait_spans 1 || fail "traced find posted no span within 5 s"
S="$(last_span)"
[ "$(field "$S" trace)" = "$TRACE" ] && [ "$(field "$S" parent)" = "$PARENT" ] && pass "span nests under the harness TRACEPARENT" || fail "span ids did not match TRACEPARENT: $S"
[ "$(field "$S" name)" = "egregore.search.find" ] && pass "span is named for the operation" || fail "span name: $(field "$S" name)"
[ "$(attr "$S" egregore.search.kind)" = "hybrid" ] && [ "$(attr "$S" egregore.search.recent_days)" = "30" ] && pass "value flags become bounded attributes" || fail "flag attributes missing: $S"
[ "$(attr "$S" egregore.search.private_result)" = "True" ] && pass "private packet is marked" || fail "private_result attribute: $(attr "$S" egregore.search.private_result)"
[ "$(attr "$S" egregore.search.results)" = "<absent>" ] && pass "private packet records no result count" || fail "private packet leaked a result count"
[ "$(attr "$S" egregore.search.stale_documents)" = "7" ] && pass "stale-index note becomes an attribute" || fail "stale_documents: $(attr "$S" egregore.search.stale_documents)"
[ "$(attr "$S" egregore.search.query)" = "<absent>" ] && pass "query text is withheld without OTEL_LOG_TOOL_DETAILS" || fail "query text leaked into the span"
[ "$(attr "$S" egregore.search.prefix)" = "<absent>" ] && pass "search prefix is withheld without OTEL_LOG_TOOL_DETAILS" || fail "search prefix leaked into the span"
grep -qF memory/private "$SPANS" && fail "search prefix value leaked into the posted body" || pass "posted body contains no private search prefix"
grep -q ep_secret_reference "$SPANS" && fail "episode reference leaked into the span" || pass "episode reference is never recorded"
[ "$(attr "$S" egregore.exit_code)" = "0" ] && [ "$(field "$S" status)" = "1" ] && pass "exit code and OK status recorded" || fail "status fields: $S"
res="$(printf '%s' "$S" | python3 -c "import json,sys; print(json.load(sys.stdin)['resource'].get('service.name'))")"
[ "$res" = "egregore-runtime" ] && pass "resource names the Egregore runtime" || fail "service.name: $res"

# 3. Visible results are counted; a failure carries ERROR status and the exit code.
ARGS=("hello" --kind keyword)
_traced egregore.search.find ARGS bash -c 'printf "1. a\n2. b\n3. c\n"; exit 1' >/dev/null; rc=$?
[ "$rc" -eq 1 ] && pass "traced call preserves a non-zero exit status" || fail "traced exit status was $rc, expected 1"
wait_spans 2 || fail "second span did not arrive"
S="$(last_span)"
[ "$(attr "$S" egregore.search.results)" = "3" ] && pass "visible result lines are counted" || fail "results: $(attr "$S" egregore.search.results)"
[ "$(attr "$S" egregore.exit_code)" = "1" ] && [ "$(field "$S" status)" = "2" ] && pass "failure sets ERROR status with the exit code" || fail "failure status: $S"

# 4. open: the source count always; paths only with OTEL_LOG_TOOL_DETAILS.
ARGS=(memory/a.md memory/b.md --offset 0 --length 400)
_traced egregore.search.open ARGS true >/dev/null
wait_spans 3 || fail "open span did not arrive"
S="$(last_span)"
[ "$(field "$S" name)" = "egregore.search.open" ] && [ "$(attr "$S" egregore.open.sources)" = "2" ] && [ "$(attr "$S" egregore.open.paths)" = "<absent>" ] && pass "open records the source count, not the paths" || fail "open attributes: $S"
OTEL_LOG_TOOL_DETAILS=1 _traced egregore.search.open ARGS true >/dev/null
wait_spans 4 || fail "detailed open span did not arrive"
S="$(last_span)"
[ "$(attr "$S" egregore.open.paths)" = "memory/a.md,memory/b.md" ] && pass "paths appear only when tool details are enabled" || fail "detailed paths: $(attr "$S" egregore.open.paths)"

# 5. A search prefix is content, just like query text and open paths.
ARGS=("hello world" --prefix memory/private --private-result)
OTEL_LOG_TOOL_DETAILS=1 _traced egregore.search.find ARGS true >/dev/null
wait_spans 5 || fail "detailed find span did not arrive"
S="$(last_span)"
[ "$(attr "$S" egregore.search.prefix)" = "memory/private" ] && pass "search prefix appears when tool details are enabled" || fail "detailed search prefix: $(attr "$S" egregore.search.prefix)"
tail -n 1 "$SPANS" | grep -qF memory/private && pass "detailed posted body contains the search prefix" || fail "detailed posted body omitted the search prefix"

# 6. An unsampled parent posts nothing.
export TRACEPARENT="00-$TRACE-$PARENT-00"
before="$(span_count)"
_traced egregore.search.find ARGS printf '1. a\n' >/dev/null
sleep 0.5
[ "$(span_count)" -eq "$before" ] && pass "unsampled trace posts no span" || fail "unsampled trace posted a span"

echo ""
echo "search-traced: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
