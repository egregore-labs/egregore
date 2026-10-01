#!/usr/bin/env bash
# Exercise the plain config reader against an isolated checkout, preserving
# stdout bytes so an empty line cannot masquerade as an unset value.
# Present-but-empty strings are unset: optional keys print nothing and
# repo_name defaults to egregore, just as when the key is absent.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
CHECKOUT="$TMP/checkout"
mkdir -p "$CHECKOUT/bin/lib" "$TMP/elsewhere"
cp "$ROOT/bin/config-get.sh" "$CHECKOUT/bin/config-get.sh"
cp "$ROOT/bin/lib/config.sh" "$CHECKOUT/bin/lib/config.sh"

ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }
fixture() { printf '%s\n' "$1" > "$CHECKOUT/egregore.json"; }

run_reader() {
  # Every call runs outside the checkout with empty CONFIG and hostile Git
  # overrides: configuration belongs to the script's own checkout.
  (
    cd "$TMP/elsewhere" || exit 1
    CONFIG='' GIT_DIR="$TMP/not-a-repo" GIT_WORK_TREE="$TMP/elsewhere" \
      GIT_INDEX_FILE="$TMP/not-an-index" GIT_OBJECT_DIRECTORY="$TMP/not-objects" \
      GIT_ALTERNATE_OBJECT_DIRECTORIES="$TMP/not-alternates" \
      GIT_COMMON_DIR="$TMP/not-common" \
      bash "$CHECKOUT/bin/config-get.sh" "$@"
  ) > "$TMP/stdout" 2> "$TMP/stderr"
}

check() { # check <description> <expected-stdout-bytes> <key>
  local description="$1" expected="$2" status=0
  shift 2
  run_reader "$@" || status=$?
  printf '%s' "$expected" > "$TMP/expected"
  if [ "$status" -eq 0 ] && cmp -s "$TMP/expected" "$TMP/stdout" \
     && [ ! -s "$TMP/stderr" ]; then
    ok "$description"
  else
    bad "$description — unexpected status ($status), stdout, or stderr"
  fi
}

reject() { # reject <description> <status> <stderr-line> [arguments...]
  local description="$1" expected_status="$2" expected_error="$3" status=0
  shift 3
  run_reader "$@" || status=$?
  printf '%s\n' "$expected_error" > "$TMP/expected"
  if [ "$status" -eq "$expected_status" ] && [ ! -s "$TMP/stdout" ] \
     && cmp -s "$TMP/expected" "$TMP/stderr"; then
    ok "$description"
  else
    bad "$description — unexpected status ($status), stdout, or stderr"
  fi
}

echo "test-config-get"

fixture '{"mode":"local"}'
check "explicit local mode → local" $'local\n' mode
fixture '{}'
check "no mode or API URL → local" $'local\n' mode
fixture '{"api_url":"https://api.example.test"}'
check "API URL without mode → connected" $'connected\n' mode
fixture '{"mode":"local","api_url":"https://api.example.test"}'
check "explicit local mode wins over API URL" $'local\n' mode
fixture '{"mode":"connected"}'
check "connected mode without API URL → local" $'local\n' mode

for key in api_url github_org org_name slug memory_repo upstream_url; do
  fixture "{\"$key\":\"value for $key\"}"
  check "$key prints its top-level string" "value for $key"$'\n' "$key"
  fixture '{}'
  check "$key absent prints no bytes" '' "$key"
  fixture "{\"$key\":null}"
  check "$key null prints no bytes" '' "$key"
  fixture "{\"$key\":\"\"}"
  check "$key present-but-empty is unset and prints no bytes" '' "$key"
  for nonstring in 7 '{}' '[]' false; do
    fixture "{\"$key\":$nonstring}"
    check "$key non-string ($nonstring) is unset and prints no bytes" '' "$key"
  done
done

fixture '{"org_name":"-n"}'
check "org_name -n is printed literally" $'-n\n' org_name
fixture '{"org_name":"-e"}'
check "org_name -e is printed literally" $'-e\n' org_name

fixture '{"github_org":"acme","repo_name":"custom"}'
check "explicit repo_name is preserved" $'custom\n' repo_name
check "repo combines organization and explicit name" $'acme/custom\n' repo
fixture '{"github_org":"acme"}'
check "repo_name defaults to egregore" $'egregore\n' repo_name
check "repo combines organization and default name" $'acme/egregore\n' repo
for unset_name in '""' null 7 '{}' '[]' true; do
  fixture "{\"github_org\":\"acme\",\"repo_name\":$unset_name}"
  check "repo_name empty/non-string ($unset_name) defaults to egregore" $'egregore\n' repo_name
  check "repo uses default for empty/non-string repo_name ($unset_name)" $'acme/egregore\n' repo
done
fixture '{}'
reject "repo fails without github_org" 1 'config: github_org is not set' repo
for unset_org in '""' null 7 '{}' '[]' false; do
  fixture "{\"github_org\":$unset_org}"
  reject "repo rejects empty/non-string github_org ($unset_org)" 1 \
    'config: github_org is not set' repo
done
fixture '{"memory_repo":"https://x/y/org-memory.git"}'
check "memory_dir removes URL path and trailing .git" $'org-memory\n' memory_dir
fixture '{"memory_repo":"https://x/y/org-memory"}'
check "memory_dir accepts URL without .git" $'org-memory\n' memory_dir
fixture '{}'
check "absent memory_repo prints no memory_dir bytes" '' memory_dir
for unset_memory in '""' null 7 '{}' '[]'; do
  fixture "{\"memory_repo\":$unset_memory}"
  check "empty/non-string memory_repo ($unset_memory) prints no memory_dir bytes" '' memory_dir
done
fixture '{"repos":["app",{"name":"site","base_branch":"main"},"docs"]}'
check "repos accepts mixed strings and objects in order" $'app\nsite\ndocs\n' repos
fixture '{"repos":[]}'
check "empty repos prints no bytes" '' repos
fixture '{}'
check "absent repos prints no bytes" '' repos

USAGE='Usage: bash bin/config-get.sh <key>'
reject "unknown key is a usage error" 2 "$USAGE" unknown
reject "two arguments are a usage error" 2 "$USAGE" mode slug
reject "missing key is a usage error" 2 "$USAGE"
reject "empty key is a usage error" 2 "$USAGE" ''
reject "key containing slash is a usage error" 2 "$USAGE" mode/slug
reject "key containing .. is a usage error" 2 "$USAGE" mode..slug

rm "$CHECKOUT/egregore.json"
reject "missing config fails without stdout" 1 \
  "config: cannot read $CHECKOUT/egregore.json" mode
for invalid_json in '[]' 'null' '"string"' '{"mode":' '' '{} {}'; do
  fixture "$invalid_json"
  reject "non-object or malformed config ($invalid_json) fails without stdout" 1 \
    "config: invalid JSON object in $CHECKOUT/egregore.json" mode
done

fixture '{"slug":"checkout"}'
printf '%s\n' '{"slug":"override"}' > "$TMP/override.json"
status=0
CONFIG="$TMP/override.json" bash "$CHECKOUT/bin/config-get.sh" slug \
  > "$TMP/stdout" 2> "$TMP/stderr" || status=$?
printf '%s\n' override > "$TMP/expected"
if [ "$status" -eq 0 ] && cmp -s "$TMP/expected" "$TMP/stdout" \
   && [ ! -s "$TMP/stderr" ]; then
  ok "explicit CONFIG selects the requested configuration"
else
  bad "explicit CONFIG was not honored"
fi

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
