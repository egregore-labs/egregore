#!/usr/bin/env bash
# Render an HTML file or a URL to a PNG with headless Chrome.
#   bin/screenshot.sh <file.html|url> <out.png> [width] [height]   (1440 x 2400)
# Chrome: $EGREGORE_CHROME when set, with no fallback when it is wrong; else
# the macOS Google Chrome app; else google-chrome or chromium on PATH. An
# aborted render (no file, or zero bytes) is retried once; each try is capped
# at 30 s. Prints "<out>: <bytes> bytes"; a failure prints one line naming the
# cause and exits non-zero.
# Headless Chrome enforces a minimum window width near 500 px, so phone checks
# use 600. Heights above about 5400 px yield no file. Run one headless Chrome
# at a time. Chrome dies at launch under the Codex sandbox, so in a minion run
# the driver renders (.claude/skills/minion/SKILL.md, LAND).
set -u

die() { printf 'screenshot: %s\n' "$1" >&2; exit "${2:-1}"; }
whole() { for n in "$@"; do case $n in '' | 0* | *[!0-9]*) return 1 ;; esac; done; }

[ $# -ge 2 ] && [ $# -le 4 ] || die "usage: bin/screenshot.sh <file.html|url> <out.png> [width] [height]" 2
input=$1 out=$2 width=${3:-1440} height=${4:-2400}
whole "$width" "$height" || die "width and height must be whole pixels, got $width x $height" 2

if [[ $input =~ ^[A-Za-z][A-Za-z0-9+.-]*:// ]] || [[ $input == data:* ]] || [[ $input == about:* ]]; then
  url=$input
else
  [ -f "$input" ] && [ -r "$input" ] || die "input file missing: $input"
  case $input in */*) dir=${input%/*} ;; *) dir=. ;; esac
  dir=$(cd -- "${dir:-/}" && pwd -P) || die "input file missing: $input"
  url=file://
  # Percent-encode every byte outside the unreserved set, so a space, "#", "?",
  # "%", a control character or a non-UTF-8 name reaches Chrome intact.
  # shellcheck disable=SC2046 # the words are od's hex pairs; splitting them is the point
  for byte in $(printf '%s' "${dir%/}/${input##*/}" | od -An -v -tx1); do
    case $byte in
      2[d-f] | 3[0-9] | 4[1-9a-f] | 5[0-9a] | 5f | 6[1-9a-f] | 7[0-9a] | 7e)
        printf -v char '%b' "\\x$byte"; url+=$char ;;
      *) url+=%$byte ;;
    esac
  done
fi

case $out in */*) outdir=${out%/*} ;; *) outdir=. ;; esac
[ -d "${outdir:-/}" ] && [ -w "${outdir:-/}" ] || die "output directory missing or not writable: ${outdir:-/}"
[ ! -d "$out" ] || die "output path is a directory: $out"

if [ -n "${EGREGORE_CHROME:-}" ]; then
  chrome=$EGREGORE_CHROME
  [ -f "$chrome" ] && [ -x "$chrome" ] || die "no Chrome found: EGREGORE_CHROME=$chrome is not an executable file"
else
  chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
  [ -x "$chrome" ] || chrome=$(command -v google-chrome || command -v chromium) \
    || die "no Chrome found: set EGREGORE_CHROME, or install Google Chrome or Chromium"
fi

pid=
trap '[ -z "$pid" ] || kill "$pid" 2>/dev/null' EXIT
trap 'exit 130' INT TERM HUP

render() { # one try; true when Chrome left a non-empty file at $out
  rm -f -- "$out"; timed_out=0 ticks=0
  "$chrome" --headless=new --disable-gpu --hide-scrollbars --window-size="$width,$height" \
    --virtual-time-budget=4000 --screenshot="$out" "$url" >/dev/null 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    [ "$ticks" -lt 150 ] || { kill -9 "$pid" 2>/dev/null; timed_out=1; break; }
    sleep 0.2; ticks=$((ticks + 1))
  done
  wait "$pid" 2>/dev/null; pid=
  [ -f "$out" ] && [ -s "$out" ]
}

if ! render && ! render; then
  cause="no file at $out"
  [ "$timed_out" = 0 ] || cause="the last try timed out after 30 s"
  [ "$height" -le 5400 ] || cause="$cause; heights above about 5400 px yield no file"
  die "render aborted twice ($cause)"
fi
printf '%s: %s bytes\n' "$out" "$(wc -c < "$out" | tr -d ' ')"
