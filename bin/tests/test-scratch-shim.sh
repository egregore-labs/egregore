#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/scratch-shim.XXXXXX")"
FIXTURE="$(cd "$FIXTURE" && pwd -P)"
trap 'rm -rf -- "$FIXTURE"' EXIT
CHECKOUT="$FIXTURE/checkout"
mkdir -p "$CHECKOUT/bin/lib" "$CHECKOUT/tmp" "$FIXTURE/no-python" "$FIXTURE/stubs"
cp "$ROOT/bin/lib/scratch.sh" "$CHECKOUT/bin/lib/"
cp "$ROOT/bin/scratch-sweep.sh" "$CHECKOUT/bin/"
cp -R "$ROOT/egregore_runtime" "$CHECKOUT/"
ln -s "$(command -v dirname)" "$FIXTURE/no-python/dirname"
source "$CHECKOUT/bin/lib/scratch.sh"

fail() { printf 'FAIL scratch-shim: %s\n' "$*" >&2; exit 1; }
one_line() { [ "$(wc -l < "$FIXTURE/stderr" | tr -d ' ')" = 1 ] || fail 'expected one stderr line'; }

printf 'body' > "$CHECKOUT/tmp/input"
EGREGORE_ROOT="$FIXTURE/outside" scratch_consume "$CHECKOUT/tmp/input" 2> "$FIXTURE/stderr"
[ ! -e "$CHECKOUT/tmp/input" ] || fail 'real scratch input survives'
[ ! -s "$FIXTURE/stderr" ] || fail 'successful consume was noisy'

printf 'document' > "$FIXTURE/document"
scratch_consume "$FIXTURE/document" 2> "$FIXTURE/stderr"
[ "$(cat "$FIXTURE/document")" = document ] || fail 'outside document changed'
[ ! -s "$FIXTURE/stderr" ] || fail 'outside document consume was noisy'

mkdir -p "$FIXTURE/caller/tmp"
printf 'checkout body' > "$CHECKOUT/tmp/body.md"
printf 'caller body' > "$FIXTURE/caller/tmp/body.md"
(cd "$FIXTURE/caller" && scratch_consume tmp/body.md) 2> "$FIXTURE/stderr"
[ "$(cat "$CHECKOUT/tmp/body.md")" = 'checkout body' ] || fail 'caller-relative path removed checkout input'
[ "$(cat "$FIXTURE/caller/tmp/body.md")" = 'caller body' ] || fail 'caller-relative outside input changed'
[ ! -s "$FIXTURE/stderr" ] || fail 'caller-relative outside input consume was noisy'

scratch_consume '' 2> "$FIXTURE/stderr"
one_line
grep -Fx 'scratch: could not remove ' "$FIXTURE/stderr" >/dev/null || fail 'empty path diagnostic'
[ "$(cat "$CHECKOUT/tmp/body.md")" = 'checkout body' ] || fail 'empty path changed checkout input'

printf 'body' > "$CHECKOUT/tmp/missing-python"
PATH="$FIXTURE/no-python" scratch_consume "$CHECKOUT/tmp/missing-python" 2> "$FIXTURE/stderr"
[ -f "$CHECKOUT/tmp/missing-python" ] || fail 'missing Python changed input'
one_line
grep -Fx "scratch: could not remove $CHECKOUT/tmp/missing-python" "$FIXTURE/stderr" >/dev/null || fail 'missing Python diagnostic'

cat > "$FIXTURE/stubs/python3" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" > "$SCRATCH_ARG_LOG"
printf 'unexpected\nmultiline\nfailure\n' >&2
exit 17
STUB
chmod +x "$FIXTURE/stubs/python3"
export SCRATCH_ARG_LOG="$FIXTURE/args"
PATH="$FIXTURE/stubs:$PATH" scratch_consume "$CHECKOUT/tmp/missing-python" 2> "$FIXTURE/stderr"
one_line
grep -Fx "scratch: could not remove $CHECKOUT/tmp/missing-python" "$FIXTURE/stderr" >/dev/null || fail 'Python failure diagnostic'

(cd "$FIXTURE/caller" && PATH="$FIXTURE/stubs:$PATH" scratch_consume tmp/body.md) 2> "$FIXTURE/stderr"
one_line
python3 - "$FIXTURE/args" "$FIXTURE/caller/tmp/body.md" "$CHECKOUT" <<'PY'
from pathlib import Path
import sys
assert Path(sys.argv[1]).read_text().splitlines() == [
    '-m', 'egregore_runtime.scratch', 'consume', sys.argv[2], '--root', sys.argv[3]]
PY

cat > "$FIXTURE/stubs/python3" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" > "$SCRATCH_ARG_LOG"
exit 0
STUB
PATH="$FIXTURE/stubs:$PATH" bash "$CHECKOUT/bin/scratch-sweep.sh" --older-than 60 --dry-run
python3 - "$FIXTURE/args" "$CHECKOUT" <<'PY'
from pathlib import Path
import sys
assert Path(sys.argv[1]).read_text().splitlines() == [
    '-m', 'egregore_runtime.scratch', 'sweep', '--root', sys.argv[2],
    '--older-than', '60', '--dry-run']
PY

python3 - "$CHECKOUT" <<'PY'
import os
from pathlib import Path
import sys
import time
root = Path(sys.argv[1])
old = root / 'tmp' / 'old'
old.write_text('old')
(root / 'tmp' / 'fresh').write_text('fresh')
then = time.time() - 7200
os.utime(old, (then, then))
PY
bash "$CHECKOUT/bin/scratch-sweep.sh" --older-than 60 --dry-run > "$FIXTURE/stdout" 2> "$FIXTURE/stderr"
[ -f "$CHECKOUT/tmp/old" ] && [ -f "$CHECKOUT/tmp/fresh" ] || fail 'dry run removed a file'
grep -Fx "$CHECKOUT/tmp/old" "$FIXTURE/stdout" >/dev/null || fail 'dry-run does not list old input'
EGREGORE_ROOT="$FIXTURE" bash "$CHECKOUT/bin/scratch-sweep.sh" --older-than 60 > "$FIXTURE/stdout" 2> "$FIXTURE/stderr"
[ ! -e "$CHECKOUT/tmp/old" ] && [ -f "$CHECKOUT/tmp/fresh" ] || fail 'age filter did not preserve fresh input'
[ -f "$FIXTURE/document" ] || fail 'sweep touched outside document'

status=0
bash "$CHECKOUT/bin/scratch-sweep.sh" --root "$FIXTURE" >/dev/null 2> "$FIXTURE/stderr" || status=$?
[ "$status" = 2 ] || fail 'root override must be a usage error'
status=0
bash "$CHECKOUT/bin/scratch-sweep.sh" --older-than -1 >/dev/null 2> "$FIXTURE/stderr" || status=$?
[ "$status" = 2 ] || fail 'negative age must be a usage error'
printf 'PASS scratch-shim: consumers and sweep preserve checkout containment and exit contracts\n'
