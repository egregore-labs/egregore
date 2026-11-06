#!/usr/bin/env bash
# bin/screenshot.sh finds Chrome, retries one aborted render, and names the
# cause when it fails.
#
# Codex sessions shipped visual artifacts nobody rendered: headless Chrome dies
# at launch under their sandbox (rnd/self-audit, finding N3). The minion driver
# now renders before LAND with bin/screenshot.sh. A stub browser stands in for
# Chrome, so these cases run the same with or without Chrome installed.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHOT="$ROOT/bin/screenshot.sh"
PASS=0
FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

echo "test-screenshot"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-screenshot.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# A PATH without Chrome: only the tools the script itself calls.
TOOLS="$WORK/tools"
mkdir -p "$TOOLS"
for tool in od rm sleep tr wc; do
  real="$(command -v "$tool")" && ln -s "$real" "$TOOLS/$tool"
done

# The stub browser records each call's arguments in $STUB_CALLS, then writes a
# PNG-shaped file to the --screenshot= path, or does not, as $STUB_MODE says.
STUB="$WORK/chrome-stub"
{
  printf '#!%s\n' "$BASH"
  cat <<'STUB'
out=
for arg in "$@"; do
  case $arg in --screenshot=*) out=${arg#--screenshot=} ;; esac
done
printf '%s\n' "$*" >> "$STUB_CALLS"
n=0
while IFS= read -r _; do n=$((n + 1)); done < "$STUB_CALLS"
case $STUB_MODE in
  never) exit 0 ;;
  first-none) [ "$n" -ge 2 ] || exit 0 ;;
  first-empty) [ "$n" -ge 2 ] || { : > "$out"; exit 0; } ;;
esac
printf '\211PNG\r\n\032\nstub-image' > "$out"
STUB
} > "$STUB"
chmod +x "$STUB"

PAGE="$WORK/page.html"
printf '<!doctype html><title>page</title><p>page</p>\n' > "$PAGE"
OUT="$WORK/shot.png"
CALLS="$WORK/calls"
BYTES="$OUT: 18 bytes" # 8 bytes of PNG signature + "stub-image"

# shoot <chrome> <mode> <args...> runs the tool on $SEARCH (a Chrome-free PATH
# unless a case says otherwise) and sets $status, $output, $calls (how many
# times Chrome ran) and $argv (the last call).
SEARCH="$TOOLS"
shoot() {
  local chrome="$1" mode="$2"
  shift 2
  rm -f "$CALLS"
  output="$(PATH="$SEARCH" EGREGORE_CHROME="$chrome" STUB_MODE="$mode" STUB_CALLS="$CALLS" \
    "$BASH" "$SHOT" "$@" 2>&1)"
  status=$?
  calls=0
  argv=""
  if [ -f "$CALLS" ]; then
    calls="$(wc -l < "$CALLS" | tr -d ' ')"
    argv="$(tail -n 1 "$CALLS")"
  fi
}
one_line() { [ -n "$output" ] && [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = 1 ]; }

shoot "$WORK/no-such-chrome" write "$PAGE" "$OUT"
if [ "$status" -ne 0 ] && [[ $output == *"no Chrome found"* ]] && one_line && [ ! -e "$OUT" ]; then
  ok "EGREGORE_CHROME at a missing path, no Chrome on PATH: no-Chrome cause, non-zero exit"
else
  bad "missing Chrome: status $status, output: $output"
fi

# A wrong override is reported, never swapped for another Chrome.
mkdir -p "$WORK/chrome-on-path"
ln -s "$STUB" "$WORK/chrome-on-path/google-chrome"
SEARCH="$TOOLS:$WORK/chrome-on-path"
shoot "$WORK/no-such-chrome" write "$PAGE" "$OUT"
SEARCH="$TOOLS"
if [ "$status" -ne 0 ] && [[ $output == *"EGREGORE_CHROME"* ]] && [ "$calls" = 0 ]; then
  ok "a wrong EGREGORE_CHROME does not fall back to a Chrome on PATH"
else
  bad "override fallback: status $status, calls $calls, output: $output"
fi

shoot "$STUB" write "$PAGE" "$OUT"
if [ "$status" -eq 0 ] && [ "$output" = "$BYTES" ] && [ "$calls" = 1 ]; then
  ok "a stub that writes a PNG: one call, prints the byte line, exit 0"
else
  bad "stub render: status $status, calls $calls, output: $output"
fi
want="--headless=new --disable-gpu --hide-scrollbars --window-size=1440,2400 --virtual-time-budget=4000 --screenshot=$OUT file:///"
if [[ $argv == "$want"*/page.html ]]; then
  ok "Chrome gets the headless flags, the 1440 x 2400 default and a file URL"
else
  bad "Chrome arguments: $argv"
fi

NAMED="$WORK/page one#"$'\303\251'"?.html"
cp "$PAGE" "$NAMED"
shoot "$STUB" write "$NAMED" "$OUT" 600 900
if [ "$status" -eq 0 ] && [[ $argv == *" --window-size=600,900 "* ]] &&
  [[ $argv == *"file:///"*"/page%20one%23%c3%a9%3f.html" ]]; then
  ok "an explicit size passes through; a space, #, é and ? in the name are percent-encoded"
else
  bad "encoded name: status $status, argv: $argv"
fi

shoot "$STUB" first-none "$PAGE" "$OUT"
if [ "$status" -eq 0 ] && [ "$output" = "$BYTES" ] && [ "$calls" = 2 ]; then
  ok "no file on the first call: retried once, succeeds"
else
  bad "retry after no file: status $status, calls $calls, output: $output"
fi

shoot "$STUB" first-empty "$PAGE" "$OUT"
if [ "$status" -eq 0 ] && [ "$output" = "$BYTES" ] && [ "$calls" = 2 ]; then
  ok "a zero-byte file on the first call: retried once, succeeds"
else
  bad "retry after empty file: status $status, calls $calls, output: $output"
fi

printf 'stale' > "$OUT"
shoot "$STUB" never "$PAGE" "$OUT"
if [ "$status" -ne 0 ] && [[ $output == *"render aborted twice"* ]] && one_line &&
  [ "$calls" = 2 ] && [ ! -e "$OUT" ]; then
  ok "a stub that never writes: two tries, the cause named, a stale file not taken as the render"
else
  bad "never writes: status $status, calls $calls, output: $output"
fi

shoot "$STUB" write "$WORK/missing.html" "$OUT"
if [ "$status" -ne 0 ] && [[ $output == *"input file missing"* ]] && one_line && [ "$calls" = 0 ]; then
  ok "a missing input file fails before Chrome is called"
else
  bad "missing input: status $status, calls $calls, output: $output"
fi

shoot "$STUB" write "$PAGE" "$OUT" 1440px
if [ "$status" -eq 2 ] && [[ $output == *"whole pixels"* ]] && [ "$calls" = 0 ]; then
  ok "a width that is not a whole number is refused before Chrome is called"
else
  bad "bad width: status $status, calls $calls, output: $output"
fi

shoot "$STUB" write "https://example.org/a?b#c" "$OUT"
if [ "$status" -eq 0 ] && [[ $argv == *" https://example.org/a?b#c" ]]; then
  ok "a URL reaches Chrome unchanged"
else
  bad "URL input: status $status, argv: $argv"
fi

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
