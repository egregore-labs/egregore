#!/usr/bin/env bash
# The retired hosted origin (October 2026 security reset) never receives a
# credential. Every resolver — shell, Python, the npm package and the
# launcher's inline copy — maps it to the hosted API from one table; every
# credential-bearing read of a saved or configured address goes through one;
# and the Claude, Codex, Pi and Prime start paths reach the same shell one.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VECTORS="$ROOT/bin/tests/fixtures/hosted-api-url-vectors.json"
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "    $2"; return 0; }

echo "Testing: hosted address resolution after the security reset"
echo ""

# --- the shell resolver answers the shared table ------------------------------------
# shellcheck source=bin/lib/config.sh
source "$ROOT/bin/lib/config.sh"
[ "$EGREGORE_HOSTED_API_ORIGIN" = "$(jq -r .hosted "$VECTORS")" ] \
  && [ "$EGREGORE_RETIRED_API_ORIGIN" = "$(jq -r .retired "$VECTORS")" ] \
  && pass "shell constants match the shared table" || fail "shell constants differ from the table"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
SCRATCH_ERR="$SCRATCH/err"
# Nothing here runs a start script, but keep any accidental one off the real registry.
export HOME="$SCRATCH/home"
mkdir -p "$HOME"

mismatches=""
count=0
refused_count=0
# NUL-separated: some inputs carry tabs and newlines on purpose.
while IFS= read -r -d '' input && IFS= read -r -d '' expected && IFS= read -r -d '' result; do
  count=$((count + 1))
  status=0
  actual="$(_hosted_api_url "$input" 2>"$SCRATCH_ERR")" || status=$?
  if [ "$result" = refused ]; then
    refused_count=$((refused_count + 1))
    { [ "$status" -ne 0 ] && [ -z "$actual" ]; } || mismatches="$mismatches [$input accepted as '$actual', want refused]"
    grep -qF "isn't a plain web address" "$SCRATCH_ERR" || mismatches="$mismatches [$input refused without saying why]"
  else
    { [ "$status" -eq 0 ] && [ "$actual" = "$expected" ]; } \
      || mismatches="$mismatches [$input → '$actual' (exit $status), want '$expected']"
  fi
  if _retired_api_url "$input"; then is_retired=retired; else is_retired=other; fi
  { [ "$result" = retired ] && [ "$is_retired" = retired ]; } || { [ "$result" != retired ] && [ "$is_retired" = other ]; } \
    || mismatches="$mismatches [$input _retired_api_url=$is_retired, want $result]"
done < <(jq -j '.cases[] | (.input // ""), "\u0000", .expected, "\u0000", .result, "\u0000"' "$VECTORS")
[ "$count" -ge 80 ] && [ "$refused_count" -ge 50 ] && [ -z "$mismatches" ] \
  && pass "_hosted_api_url and _retired_api_url answer all $count cases ($refused_count refused)" || fail "shell resolver" "$mismatches"
silent="$(EGREGORE_ADDRESS_NOTICE=shown _hosted_api_url 'https://a\@b' 2>&1)"
[ -z "$silent" ] && pass "EGREGORE_ADDRESS_NOTICE=shown keeps a refusal quiet" || fail "refusal notice not silenced" "$silent"
shopt -s nocasematch
nocase="$(_hosted_api_url 'HTTPS://egregore-production-55f2.up.railway.app' 2>/dev/null || echo refused)"
[ "$nocase" = refused ] && shopt -q nocasematch \
  && pass "a caller's nocasematch neither widens the rule nor is lost" || fail "nocasematch leaks into the rule" "$nocase"
shopt -u nocasematch

# --- the transports agree with every address the resolvers let through ---------------
# A plain or retired case must reach the host of its answer under every
# transport: curl (the shell's), Node's WHATWG URL and urllib's Request, which
# applies unwrap() before it reads the host. The input of a retired case must
# reach the retired host (otherwise the rewrite is wrong), and the input of a
# plain case the same host as its answer. curl answers without touching the
# network: --connect-to sends every connection to a dead local port. A parser
# change in a later curl, Node or Python that reads a plain address differently
# fails here.
curl_host() {
  local host
  host="$(curl -q -sS --globoff --noproxy '*' --max-time 2 --connect-to ::127.0.0.1:1 -o /dev/null -w '%{url.host}' -- "$1" 2>/dev/null || true)"
  host="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')"
  while [ "${host%.}" != "$host" ]; do host="${host%.}"; done
  printf '%s' "$host"
}
plain_host() { # the host the plain rule reads in an answer
  [[ "$1" =~ $EGREGORE_PLAIN_API_URL ]] || return 1
  local host
  host="$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')"
  while [ "${host%.}" != "$host" ]; do host="${host%.}"; done
  printf '%s' "$host"
}
retired_host="${EGREGORE_RETIRED_API_ORIGIN#https://}"
if [ "$(curl_host "$EGREGORE_RETIRED_API_ORIGIN/")" = "$retired_host" ]; then
  drift=""
  checked=0
  while IFS= read -r -d '' input && IFS= read -r -d '' expected && IFS= read -r -d '' result; do
    case "$result" in retired|plain) ;; *) continue ;; esac
    checked=$((checked + 1))
    want="$(plain_host "$expected")" || { drift="$drift [answer $expected is not plain]"; continue; }
    seen="$(curl_host "$expected")"
    [ "$seen" = "$want" ] || drift="$drift [curl sends $expected to '$seen', want '$want']"
    trimmed="$(_api_url_trim "$input")"
    seen="$(curl_host "$trimmed")"
    if [ "$result" = retired ]; then want="$retired_host"; fi
    [ "$seen" = "$want" ] || drift="$drift [curl sends input $trimmed to '$seen', want '$want']"
  done < <(jq -j '.cases[] | (.input // ""), "\u0000", .expected, "\u0000", .result, "\u0000"' "$VECTORS")
  [ "$checked" -ge 25 ] && [ -z "$drift" ] && pass "curl connects to the resolved host for all $checked accepted cases" \
    || fail "curl reads an accepted address differently" "$drift"
else
  echo "  - skipped: this curl cannot report the host it connects to (needs curl 8.1 or later)"
fi
whatwg_out="$(node - "$VECTORS" <<'JS'
const table = JSON.parse(require("node:fs").readFileSync(process.argv[2], "utf8"));
const retired = new URL(table.retired).hostname;
const plain = /^https?:\/\/([A-Za-z0-9._-]+)(:[0-9]{1,5})?(\/[A-Za-z0-9._~/-]*)?$/;
const norm = (host) => host.toLowerCase().replace(/\.+$/, "");
const host = (input) => { try { return norm(new URL(input).hostname); } catch { return ""; } };
const bad = [];
let checked = 0;
for (const c of table.cases) {
  if (c.result !== "retired" && c.result !== "plain") continue;
  checked++;
  const want = norm(plain.exec(c.expected)[1]);
  if (host(c.expected) !== want) bad.push(`${c.expected} → '${host(c.expected)}', want '${want}'`);
  const input = c.input.replace(/^[ \t\n\r\f\v]+|[ \t\n\r\f\v]+$/g, "");
  const inputWant = c.result === "retired" ? retired : want;
  if (host(input) !== inputWant) bad.push(`input ${JSON.stringify(input)} → '${host(input)}', want '${inputWant}'`);
}
console.log(checked < 25 ? `only ${checked} accepted cases` : bad.length ? bad.join(" ") : "ok");
JS
)"
[ "$whatwg_out" = ok ] && pass "Node's WHATWG URL connects to the resolved host for every accepted case" || fail "WHATWG reading" "$whatwg_out"
python_out="$(python3 -I - "$VECTORS" <<'PY'
import json, re, sys
from urllib.request import Request
table = json.load(open(sys.argv[1]))
retired = table["retired"].split("://", 1)[1]
plain = re.compile(r"https?://([A-Za-z0-9._-]+)(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?")
def norm(host):
    return re.sub(r":[0-9]*$", "", host).lower().rstrip(".")
def host(url):
    try:
        return norm(Request(url).host or "")  # Request applies unwrap() first
    except ValueError:
        return ""
bad, checked = [], 0
for case in table["cases"]:
    if case["result"] not in ("retired", "plain"):
        continue
    checked += 1
    want = norm(plain.fullmatch(case["expected"]).group(1))
    if host(case["expected"]) != want:
        bad.append(f"{case['expected']} -> {host(case['expected'])!r}")
    text = case["input"].strip(" \t\n\r\f\v")
    input_want = retired if case["result"] == "retired" else want
    if host(text) != input_want:
        bad.append(f"input {text!r} -> {host(text)!r}, want {input_want!r}")
print(f"only {checked} accepted cases" if checked < 25 else "ok" if not bad else " ".join(bad))
PY
)"
[ "$python_out" = ok ] && pass "urllib's Request connects to the resolved host for every accepted case" || fail "urllib reading" "$python_out"

# --- egregore.json and config-get.sh resolve -----------------------------------------
printf '%s\n' '{"mode":"connected","api_url":"https://egregore-production-55f2.up.railway.app/","slug":"acme"}' > "$SCRATCH/retired.json"
printf '%s\n' '{"mode":"connected","api_url":"https://egregore.example.org/","slug":"acme"}' > "$SCRATCH/custom.json"
printf '%s\n' '{"mode":"connected","api_url":"https://selfhost.example\\@egregore-production-55f2.up.railway.app/","slug":"acme"}' > "$SCRATCH/odd.json"
[ "$(CONFIG="$SCRATCH/retired.json" _config_api_url)" = "https://api.egregore.xyz" ] \
  && pass "_config_api_url resolves a saved retired address" || fail "_config_api_url" "$(CONFIG="$SCRATCH/retired.json" _config_api_url)"
[ "$(CONFIG="$SCRATCH/custom.json" _config_api_url)" = "https://egregore.example.org" ] \
  && pass "_config_api_url keeps a custom origin" || fail "_config_api_url custom"
[ "$(CONFIG="$SCRATCH/retired.json" bash "$ROOT/bin/config-get.sh" api_url)" = "https://api.egregore.xyz" ] \
  && pass "config-get.sh api_url hands skills the resolved address" || fail "config-get.sh api_url"
[ "$(CONFIG="$SCRATCH/custom.json" bash "$ROOT/bin/config-get.sh" api_url)" = "https://egregore.example.org" ] \
  && pass "config-get.sh keeps a custom origin" || fail "config-get.sh custom"
odd_status=0
odd_out="$(CONFIG="$SCRATCH/odd.json" bash "$ROOT/bin/config-get.sh" api_url 2>"$SCRATCH_ERR")" || odd_status=$?
[ "$odd_status" -ne 0 ] && [ -z "$odd_out" ] && [ "$(grep -c "isn't a plain web address" "$SCRATCH_ERR")" = 1 ] \
  && pass "config-get.sh refuses an odd saved address, says why once, and hands skills nothing" \
  || fail "config-get.sh odd address" "exit $odd_status, out '$odd_out', err $(cat "$SCRATCH_ERR")"

# --- a Coder workspace sends its key and token only to a plain address ------------------
# workspace-init.sh runs against stand-ins for curl and git; each logs what it
# would reach. A retired API_URL reaches the hosted API; an odd one, nothing.
WS="$SCRATCH/workspace"
mkdir -p "$WS/inst/bin/lib" "$WS/stubs"
cp "$ROOT/bin/workspace-init.sh" "$WS/inst/bin/"
cp "$ROOT/bin/lib/config.sh" "$WS/inst/bin/lib/"
printf '%s\n' '#!/usr/bin/env bash' 'for a in "$@"; do case "$a" in http://*|https://*) printf "%s\n" "$a" >> "$WS_LOG" ;; esac; done' 'exit 22' > "$WS/stubs/curl"
printf '%s\n' '#!/usr/bin/env bash' '[ "$1" = clone ] && mkdir -p "$3/.git"' 'exit 0' > "$WS/stubs/git"
chmod 700 "$WS/stubs/curl" "$WS/stubs/git"
ws_run() {  # ws_run API_URL -> the URLs curl was asked to reach, one per line
  rm -rf "$WS/home" && mkdir -p "$WS/home" && : > "$WS/log"
  env -i PATH="$WS/stubs:$PATH" HOME="$WS/home" WS_LOG="$WS/log" API_URL="$1" ORG_SLUG=acme GITHUB_ORG=acme \
    REPO_NAME=egregore CODER_USERNAME=ada GITHUB_TOKEN=gh-fixture EGREGORE_API_KEY=ek_fixture \
    bash "$WS/inst/bin/workspace-init.sh" >/dev/null 2>&1
  cat "$WS/log"
}
ws_retired="$(ws_run 'https://egregore-production-55f2.up.railway.app/')"
[ -n "$ws_retired" ] && ! grep -qv '^https://api\.egregore\.xyz/' <<< "$ws_retired" \
  && pass "workspace-init.sh sends a retired API_URL's requests to the hosted API" || fail "workspace-init retired" "$ws_retired"
ws_odd=""
for odd in 'https://selfhost.example\@egregore-production-55f2.up.railway.app/' 'http://egregore-production-55f2.up.railway.ap{p,p}' \
  'https://%65gregore-production-55f2.up.railway.app'; do
  sent="$(ws_run "$odd")"
  [ -z "$sent" ] || ws_odd="$ws_odd [$odd: $sent]"
done
[ -z "$ws_odd" ] && pass "workspace-init.sh sends nothing for an API_URL that is not plain" || fail "workspace-init odd" "$ws_odd"

# --- the other languages answer the same table ----------------------------------------
py_out="$(cd "$ROOT" && PYTHONSAFEPATH=1 PYTHONPATH="$ROOT" python3 - "$VECTORS" 2>"$SCRATCH_ERR" <<'PY'
import json, sys
from urllib.request import Request
from egregore_runtime.hosted_api import (HOSTED_API_ORIGIN, RETIRED_API_ORIGIN, RefusedApiAddress,
                                         credential_request, hosted_api_url, retired_api_url)
table = json.load(open(sys.argv[1]))
bad = []
for c in table["cases"]:
    try:
        got = hosted_api_url(c["input"])
        result = "empty" if not got else "retired" if retired_api_url(c["input"]) else "plain"
    except RefusedApiAddress:
        got, result = "", "refused"
    if (result, got) != (c["result"], c["expected"]):
        bad.append(repr(c["input"]))
    if c["result"] != "retired" and retired_api_url(c["input"]):
        bad.append("retired_api_url " + repr(c["input"]))
    if c["result"] in ("retired", "plain"):
        credential_request(got + "/api/x?y=1")  # a URL built from an answer is accepted
    # credential_request never builds a request urllib would send to the retired host.
    text = str(c["input"] or "").strip(" \t\n\r\f\v")
    try:
        reaches = (Request(text).host or "").split(":")[0].lower().rstrip(".") == RETIRED_API_ORIGIN.split("://")[1]
    except ValueError:
        reaches = False
    if reaches:
        try:
            credential_request(text)
            bad.append("credential_request accepted " + repr(text))
        except RefusedApiAddress:
            pass
    exact = hosted_api_url(c["input"], exact=True)
    if exact != (c["expected"] if c["result"] == "retired" else "" if c["input"] is None else c["input"]):
        bad.append("exact " + repr(c["input"]))
print("ok" if not bad and HOSTED_API_ORIGIN == table["hosted"] and RETIRED_API_ORIGIN == table["retired"] else bad)
PY
)"
[ "$py_out" = ok ] && [ "$(grep -c "isn't a plain web address" "$SCRATCH_ERR")" = 1 ] \
  && pass "egregore_runtime.hosted_api answers the same table and says why once per process" || fail "Python resolver" "$py_out $(cat "$SCRATCH_ERR")"

node_out="$(node - "$ROOT" "$VECTORS" <<'JS'
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const [root, vectors] = process.argv.slice(2);
const table = JSON.parse(fs.readFileSync(vectors, "utf8"));
const lib = require(path.join(root, "packages/create-egregore/lib/hosted-api.js"));
const launcher = fs.readFileSync(path.join(root, "packages/create-egregore/assets/egregore-launcher.js"), "utf8");
const start = launcher.indexOf("const HOSTED_API_ORIGIN");
const end = launcher.indexOf("const CONNECT_API_URL");
const ctx = vm.createContext({});
vm.runInContext(launcher.slice(start, end) + "\nthis.inline = { HOSTED_API_ORIGIN, RETIRED_API_ORIGIN, RefusedApiAddressError, retiredApiUrl, hostedApiUrl };", ctx);
const bad = [];
for (const impl of [lib, ctx.inline]) {
  if (impl.HOSTED_API_ORIGIN !== table.hosted || impl.RETIRED_API_ORIGIN !== table.retired) bad.push("constants");
  for (const c of table.cases) {
    let got, result;
    try {
      got = impl.hostedApiUrl(c.input);
      result = !got ? "empty" : impl.retiredApiUrl(c.input) ? "retired" : "plain";
    } catch (error) {
      if (!(error instanceof impl.RefusedApiAddressError)) throw error;
      got = ""; result = "refused";
    }
    if (got !== c.expected || result !== c.result) bad.push(JSON.stringify(c.input));
  }
}
console.log(start < 0 || end < start ? "launcher resolver not found" : bad.length ? bad.join(" ") : "ok");
JS
)"
[ "$node_out" = ok ] && pass "the npm package and the launcher's inline copy answer the same table" || fail "Node resolvers" "$node_out"

# --- no credential-bearing read bypasses a resolver -------------------------------------
# Every line that reads a saved or configured hosted address (egregore.json's
# api_url or an address override) must resolve it on the same line, or be one
# of the reads below that only decides whether an instance is Connected, shows
# the recovery notice, or fingerprints a cache. A new request that reads the
# address directly fails here: route it through _hosted_api_url /
# _config_api_url (shell), hosted_api_url (Python) or hostedApiUrl (Node).
ALLOW="$SCRATCH/allow"
cat > "$ALLOW" <<'ALLOW'
bin/lib/config.sh	EGREGORE_CONNECTED_JQ='(.mode // "") != "local" and ((.api_url // "") | length > 0)'
bin/lib/health-footer.sh	origin=$(jq -r '.api_url // empty' "$CONFIG" 2>/dev/null) || return 0
bin/attendant.sh	elif ! jq -e '(.mode // "") != "local" and ((.api_url // "") | length > 0)' "$CONFIG" >/dev/null 2>&1; then
bin/attendant.sh	api_url=$(jq -r '.api_url // empty' "$CONFIG" 2>/dev/null)
bin/connect-refresh.sh	API_URL=$(jq -r '.api_url // empty' egregore.json 2>/dev/null)
bin/lib/context.sh	_API_URL=$(jq -r '.api_url // empty' "$SCRIPT_DIR/egregore.json" 2>/dev/null)
bin/lib/metrics.sh	_API_URL=$(jq -r '.api_url // empty' "$_root/egregore.json" 2>/dev/null || echo "")
bin/runtime-identity.sh	mode="$(jq -r 'if (.mode // "local") == "connected" or (.api_url // "") != "" then "connected" else "local" end' "$CONFIG" 2>/dev/null || echo local)"
bin/session-start.sh	R_API_URL=$(jq -r '.api_url // empty' "$CONFIG" 2>/dev/null || true)
bin/settings.sh	effective_url="${effective_url:-$(jq -r '.api_url // empty' "$CONFIG" 2>/dev/null)}"
bin/settings.sh	(.api_url | nonblank) and $has_key) as $configured |
bin/settings.sh	[ -n "$(jq -r '.api_url // empty' "$CONFIG" 2>/dev/null)" ] && echo "  connected org: for the invite link + Telegram, run /invite $h" ;;
bin/settings.sh	[ -n "$(jq -r '.api_url // empty' "$CONFIG" 2>/dev/null)" ] && echo "  connected org: for full deprovision (Supabase/Neo4j), run /delete-user $h" ;;
bin/settings.sh	local effective_url="${EGREGORE_API_URL:-}" effective_key="${EGREGORE_API_KEY:-}" org_route=false
bin/settings.sh	effective_url="${effective_url:-$(grep '^EGREGORE_API_URL=' "$SCRIPT_DIR/.env" 2>/dev/null | cut -d'=' -f2- || true)}"
bin/pi-product-workflows.mjs	if (config.slug && config.mode !== "local" && config.api_url) {
bin/pi-product-workflows.mjs	if (config.mode !== "local" && config.api_url) {
bin/post-update.sh	saved_api_url() { jq -r '.api_url | strings' 2>/dev/null <<< "$1" || true; }
bin/post-update.sh	other_keys() { jq -cS 'del(.api_url)' 2>/dev/null <<< "$1"; }
egregore_runtime/adapters/invitation.py	connected = bool(self.config.get("api_url")) or self.config.get("mode") == "connected"
egregore_runtime/artifact_publication.py	if config.get("mode") != "connected" or config.get("api_url") != ORIGIN or config.get("slug") != ORG:
egregore_runtime/identity.py	if str(config.get("mode") or "local") == "connected" or config.get("api_url"):
egregore_runtime/identity.py	and (str(config.get("mode") or "local") == "connected" or config.get("api_url"))
egregore_runtime/issue_reporting.py	if (config.get('mode') != 'connected' and not config.get('api_url')) or not value:
egregore_runtime/onboarding.py	connected = bool(config.get("api_url")) or config.get("mode") == "connected"
egregore_runtime/scrolls.py	return config.get("mode") == "connected" and bool(config.get("api_url"))
egregore_runtime/status_cli.py	mode = str(config.get("mode") or ("connected" if config.get("api_url") else "local"))
ALLOW

# A read: jq's .api_url, _config_val api_url, Python's config.get("api_url")
# or ["api_url"], JS/TS's .api_url (the connectors' transports included), or
# an expansion of an address override.
# Loading an override from .env (grep '^NAME=') is not a read: the value is
# resolved on the line that uses it, which this check holds.
READS='\.api_url|_config_val api_url|get\(["'"'"']api_url|\[["'"'"']api_url["'"'"']\]|\$\{(EGREGORE_API_URL|EGREGORE_CONNECT_API_URL|EGREGORE_NOTIFY_RELAY_URL|EMISSARY_API_URL)|environ(\.get\(|\[)["'"'"'](EGREGORE_API_URL|EGREGORE_CONNECT_API_URL|EGREGORE_NOTIFY_RELAY_URL|EMISSARY_API_URL)|process\.env\.(EGREGORE_API_URL|EGREGORE_CONNECT_API_URL|EGREGORE_NOTIFY_RELAY_URL|EMISSARY_API_URL)'
ENV_LOAD="grep '\\^(EGREGORE_API_URL|EGREGORE_CONNECT_API_URL|EGREGORE_NOTIFY_RELAY_URL|EMISSARY_API_URL)="
scan_list="$SCRATCH/scan"
# Outside a git checkout (an unpacked release, a copied tree) the same files
# come from find, so the scan never passes by seeing nothing.
in_git=false
git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 && in_git=true
if [ "$in_git" = true ]; then
  (cd "$ROOT" && git ls-files -- 'bin/*.sh' 'bin/lib/*.sh' 'bin/*.py' 'bin/*.mjs' 'bin/*.cjs' 'bin/*.js' \
    'egregore_runtime/*.py' '.claude/hooks/*' '.claude/skills/*/scripts/*' 'bin/connector-*/src/*.ts' \
    | grep -v -E '^bin/tests/|/tests?/' ) > "$scan_list"
else
  (cd "$ROOT" && find bin egregore_runtime .claude/hooks .claude/skills -type f \( \
      \( -path 'bin/*' \( -name '*.sh' -o -name '*.py' -o -name '*.mjs' -o -name '*.cjs' -o -name '*.js' \) \) \
      -o -path 'egregore_runtime/*.py' -o -path '.claude/hooks/*' -o -path '.claude/skills/*/scripts/*' \
      -o -path 'bin/connector-*/src/*.ts' \) 2>/dev/null \
    | grep -v -E '^bin/tests/|/tests?/|/node_modules/|/__pycache__/' | sort ) > "$scan_list"
fi
scanned="$(wc -l < "$scan_list" | tr -d ' ')"
[ "$scanned" -ge 300 ] && grep -qx 'bin/lib/config.sh' "$scan_list" && grep -qx 'egregore_runtime/hosted_api.py' "$scan_list" \
  && pass "the address-read scan covers $scanned shipped files" \
  || fail "the address-read scan saw too few files to mean anything" "$scanned files (git checkout: $in_git)"
offenders=""
while IFS= read -r file; do
  while IFS= read -r line; do
    text="${line#*:}"
    trimmed="$(printf '%s' "$text" | sed -e 's/^[[:space:]]*//')"
    case "$trimmed" in '#'*|'//'*|'"""'*) continue ;; esac
    case "$text" in *_hosted_api_url*|*_config_api_url*|*hosted_api_url\(*|*hostedApiUrl\(*) continue ;; esac
    grep -qxF "$file	$trimmed" "$ALLOW" && continue
    grep -qE "$ENV_LOAD" <<< "$text" && continue
    offenders="$offenders
    $file:${line%%:*}: $trimmed"
  done < <(grep -n -E "$READS" "$ROOT/$file" 2>/dev/null || true)
done < "$scan_list"
[ -z "$offenders" ] && pass "every credential-bearing address read resolves the retired origin" \
  || fail "address reads that bypass the resolver (route them, or allowlist a non-request check here)" "$offenders"

# The allowlist itself stays honest: each entry still exists.
stale=""
while IFS=$'\t' read -r file entry; do
  grep -qF -- "$entry" "$ROOT/$file" 2>/dev/null || stale="$stale [$file: $entry]"
done < "$ALLOW"
[ -z "$stale" ] && pass "every allowlisted non-request read still exists" || fail "stale allowlist entries" "$stale"

# Defaults that send anything to a hosted address never name the retired one.
literal=""
constants=0
literal_hits() {
  if [ "$in_git" = true ]; then
    (cd "$ROOT" && git grep -n -F 'egregore-production-55f2.up.railway.app' -- bin egregore_runtime .claude/hooks .claude/skills ':!bin/tests' ':!**/*.md' 2>/dev/null || true)
  else
    (cd "$ROOT" && grep -rnI -F --exclude='*.md' --exclude-dir=tests --exclude-dir=node_modules --exclude-dir=__pycache__ 'egregore-production-55f2.up.railway.app' bin egregore_runtime .claude/hooks .claude/skills 2>/dev/null || true)
  fi
}
while IFS= read -r hit; do
  case "$hit" in
    bin/lib/config.sh:*EGREGORE_RETIRED_API_ORIGIN=*|egregore_runtime/hosted_api.py:*'RETIRED_API_ORIGIN = '*|bin/connector-google/src/hosted-api.ts:*'export const RETIRED_API_ORIGIN = '*)
      constants=$((constants + 1)) ;;
    bin/lib/health-footer.sh:*) ;;  # the recovery notice matches both origins by design
    *) literal="$literal
    $hit" ;;
  esac
done < <(literal_hits)
[ -z "$literal" ] && [ "$constants" -ge 3 ] && pass "no shipped script names the retired origin outside the resolvers and the notice" \
  || fail "retired origin literals (or a scan that found not even the resolvers' own constants: $constants)" "$literal"

# --- every runtime's start path reaches the same shell resolver -----------------------------
for entry in bin/session-start.sh bin/codex-session-start.sh; do
  grep -q 'source "$SCRIPT_DIR/bin/lib/config.sh"' "$ROOT/$entry" \
    && grep -q 'runtime-identity.sh" ensure' "$ROOT/$entry" && grep -q 'person.sh" sync' "$ROOT/$entry" \
    && pass "$entry loads the resolver and runs identity repair through it" || fail "$entry misses the shared resolver path"
done
for entry in bin/pi-session-start.sh bin/prime-session-start.sh; do
  grep -q 'exec bash "$SCRIPT_DIR/bin/codex-session-start.sh"' "$ROOT/$entry" \
    && pass "$entry starts through the Codex path" || fail "$entry has its own start path"
done
for script in bin/runtime-identity.sh bin/person.sh; do
  grep -q 'bin/lib/config.sh"' "$ROOT/$script" && grep -q '_config_api_url\|_hosted_api_url' "$ROOT/$script" \
    && pass "$script resolves its hosted address" || fail "$script reads its address directly"
done
stale=""
for runtime in claude codex pi prime; do
  for file in bin/lib/config.sh bin/runtime-identity.sh bin/person.sh bin/config-get.sh; do
    packaged="$ROOT/packages/create-egregore/runtime/$runtime/$file"
    [ -f "$packaged" ] || { stale="$stale $runtime/$file(missing)"; continue; }
    cmp -s "$ROOT/$file" "$packaged" || stale="$stale $runtime/$file"
  done
done
[ -z "$stale" ] && pass "every packaged runtime carries the same resolver" \
  || fail "stale packaged copies; rebuild the runtime bundles" "$stale"

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
