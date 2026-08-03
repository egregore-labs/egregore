#!/bin/bash
set -e
WT="$(cd "$(dirname "$0")/.." && pwd)"
OUT=$(mktemp -d -t sweep3-XXXXXX)
SB="$OUT/root"
mkdir -p "$SB"
git init --bare -q "$OUT/origin.git"
git clone -q "$OUT/origin.git" "$OUT/seed" 2>/dev/null
cd "$OUT/seed" && git checkout -qb develop && git config user.email t@t && git config user.name tester
mkdir -p bin/lib
cp "$WT/bin/session-autosave.sh" "$WT/bin/handoff-save-egregore.sh" bin/
cp "$WT/bin/lib/noncode.sh" "$WT/bin/lib/config.sh" bin/lib/
printf '.claude/\n.egregore-state.json\n' > .gitignore
printf '%s\n' '{"base_branch":"develop","mode":"local"}' > egregore.json
echo base > README.md && git add -A && git commit -qm init && git push -q origin develop
cd / && rm -rf "$OUT/seed"
git clone -q "$OUT/origin.git" "$OUT/co" 2>/dev/null
shopt -s dotglob && mv "$OUT"/co/* "$SB/" && rmdir "$OUT/co"
git -C "$SB" config user.email t@t && git -C "$SB" config user.name tester && git -C "$SB" checkout -q develop
mkdir -p "$SB/docs" && echo leftover > "$SB/docs/leftover.md" && touch -t 202607200800 "$SB/docs/leftover.md"
mkdir -p "$SB/.claude/worktrees"
for w in wt-a wt-b; do
  git clone -q "$OUT/origin.git" "$SB/.claude/worktrees/$w" 2>/dev/null
  git -C "$SB/.claude/worktrees/$w" config user.email t@t
  git -C "$SB/.claude/worktrees/$w" config user.name tester
  git -C "$SB/.claude/worktrees/$w" checkout -q develop
  mkdir -p "$SB/.claude/worktrees/$w/docs"
done
echo rescue > "$SB/.claude/worktrees/wt-a/docs/rescue.md" && touch -t 202607200800 "$SB/.claude/worktrees/wt-a/docs/rescue.md"
echo fresh > "$SB/.claude/worktrees/wt-b/docs/fresh.md"
rm -f /tmp/.egregore-autosave-* 2>/dev/null || true
export EGREGORE_AUTOSAVE_LOG="$OUT/autosave.log"

FAIL=0
check() { # label expected actual
  if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAIL=1; fi
}

# Opt-in default: with no state file anywhere, autosave must do NOTHING.
bash "$SB/bin/session-autosave.sh" --dir "$SB/.claude/worktrees/wt-a" >/dev/null
check "default off: untouched" 1 "$(git -C "$SB/.claude/worktrees/wt-a" status --porcelain | wc -l | tr -d ' ')"

# Opt the sandbox user in (root state is the fallback for all checkouts).
echo '{"autosave_enabled":true}' > "$SB/.egregore-state.json"
rm -f /tmp/.egregore-autosave-* 2>/dev/null || true

bash "$SB/bin/session-autosave.sh" --sweep
sleep 3
check "root rescued (clean)"        0 "$(git -C "$SB" status --porcelain | wc -l | tr -d ' ')"
check "root restored to develop"    develop "$(git -C "$SB" branch --show-current)"
check "wt-a rescued (clean)"        0 "$(git -C "$SB/.claude/worktrees/wt-a" status --porcelain | wc -l | tr -d ' ')"
check "wt-b untouched (idle guard)" 1 "$(git -C "$SB/.claude/worktrees/wt-b" status --porcelain | wc -l | tr -d ' ')"
check "distinct autosave branches"  2 "$(git ls-remote --heads "$OUT/origin.git" 'refs/heads/dev/tester/autosave-*' | wc -l | tr -d ' ')"
check "ledger recorded both rescues" 2 "$(grep -c '|autosave|' "$OUT/autosave.log" 2>/dev/null || echo 0)"

# Direct (Stop-hook style) save must print a user-visible notice
NOTICE=$(bash "$SB/bin/session-autosave.sh" --dir "$SB/.claude/worktrees/wt-b")
case "$NOTICE" in
  *"auto-saved: 1 non-coding file"*) echo "PASS: stop-hook notice printed" ;;
  *) echo "FAIL: stop-hook notice printed (got '$NOTICE')"; FAIL=1 ;;
esac
check "ledger recorded direct save" 3 "$(grep -c '|autosave|' "$OUT/autosave.log" 2>/dev/null || echo 0)"

# --- Consent gate: publish gate vs auto (gh shimmed to observe merge calls) --
mkdir -p "$OUT/shim"
GH_LOG="$OUT/gh-calls.log"
cat > "$OUT/shim/gh" <<SHIM
#!/bin/bash
echo "\$1 \$2" >> "$GH_LOG"
case "\$1 \$2" in
  "pr list")   echo "" ;;
  "pr create") echo "https://github.com/x/y/pull/77" ;;
  "pr merge")  exit 0 ;;
esac
exit 0
SHIM
chmod +x "$OUT/shim/gh"

mkwt() { # name
  git clone -q "$OUT/origin.git" "$SB/.claude/worktrees/$1" 2>/dev/null
  git -C "$SB/.claude/worktrees/$1" config user.email t@t
  git -C "$SB/.claude/worktrees/$1" config user.name tester
  git -C "$SB/.claude/worktrees/$1" checkout -q develop
  mkdir -p "$SB/.claude/worktrees/$1/docs"
  echo x > "$SB/.claude/worktrees/$1/docs/note.md"
}

# default publish=gate: PR created, merge NEVER called, ledger says staged
mkwt wt-gate
PATH="$OUT/shim:$PATH" bash "$SB/bin/session-autosave.sh" --dir "$SB/.claude/worktrees/wt-gate" >/dev/null
check "gate: pr created"          1 "$(grep -c '^pr create$' "$GH_LOG" 2>/dev/null || true)"
check "gate: merge never called"  0 "$(grep -c '^pr merge$' "$GH_LOG" 2>/dev/null || true)"
check "gate: ledger staged"       1 "$(grep -c '|77|staged|' "$OUT/autosave.log" 2>/dev/null || true)"

# publish=auto (per-user opt-up): merge IS called, ledger says merged
mkwt wt-auto
echo '{"autosave_publish":"auto"}' > "$SB/.claude/worktrees/wt-auto/.egregore-state.json"
PATH="$OUT/shim:$PATH" bash "$SB/bin/session-autosave.sh" --dir "$SB/.claude/worktrees/wt-auto" >/dev/null
check "auto: merge called"        1 "$(grep -c '^pr merge$' "$GH_LOG" 2>/dev/null || true)"
check "auto: ledger merged"       1 "$(grep -c '|77|merged|' "$OUT/autosave.log" 2>/dev/null || true)"

# enabled=false: nothing captured at all
mkwt wt-off
echo '{"autosave_enabled":false}' > "$SB/.claude/worktrees/wt-off/.egregore-state.json"
PATH="$OUT/shim:$PATH" bash "$SB/bin/session-autosave.sh" --dir "$SB/.claude/worktrees/wt-off" >/dev/null
check "off: untouched"            1 "$(git -C "$SB/.claude/worktrees/wt-off" status --porcelain | wc -l | tr -d ' ')"

# scope=handoffs: core repo never touched ambiently
mkwt wt-scope
echo '{"autosave_scope":"handoffs"}' > "$SB/.claude/worktrees/wt-scope/.egregore-state.json"
PATH="$OUT/shim:$PATH" bash "$SB/bin/session-autosave.sh" --dir "$SB/.claude/worktrees/wt-scope" >/dev/null
check "scope=handoffs: untouched" 1 "$(git -C "$SB/.claude/worktrees/wt-scope" status --porcelain | wc -l | tr -d ' ')"

rm -rf "$OUT"
rm -f /tmp/.egregore-autosave-* 2>/dev/null || true
[ "$FAIL" = "0" ] && echo "session-autosave smoke: ok"
exit "$FAIL"
