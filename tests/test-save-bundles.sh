#!/usr/bin/env bash
# Test: bin/agent.sh save regenerates the derived views and runtime bundles
# before it commits.
# Covers:
#   bin/agent.sh (derivation_inputs, derivation_due, regenerate_derived, cmd_save)
#
# Each case runs the real bridge in an isolated repository with a local bare
# origin. Stubs stand in for every generator, the way npm is stubbed: a stub npm
# first on PATH, and stub sync and render scripts in the fixture's bin/. Each
# records its call in one log, so the order is visible, and writes outputs
# from its inputs the way the real generator reads them; the npm stub builds a
# marker under the runtime path from the files Git tracks. The real generators
# never run here.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
AGENT_SH="$SCRIPT_DIR/bin/agent.sh"
MARKER="packages/create-egregore/runtime/codex/stub-build.txt"
REVIEW="specs: review the hand-written Codex sections in bin/codex-render-spec.mjs: Rules"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "    → $2"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Hermetic Git: no user or system config (hooks, signing, default branch).
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=tester GIT_AUTHOR_EMAIL=tester@example.test
export GIT_COMMITTER_NAME=tester GIT_COMMITTER_EMAIL=tester@example.test
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE EGREGORE_OPERATION_ID
export EGREGORE_MEMORY_DIR="$TMP/no-memory"
NPM_FAIL=0
RENDER_FAIL=""

mkdir -p "$TMP/stub"
cat > "$TMP/stub/npm" <<'STUB'
#!/usr/bin/env bash
# Stands in for npm: records the call, then builds like the real builders,
# from the files Git tracks, so a tracked file missing from disk fails.
printf '%s|%s\n' "$PWD" "$*" >> "$NPM_LOG"
printf 'npm\n' >> "$CALLS_LOG"
if [ "${NPM_FAIL:-0}" = 1 ]; then
  echo "builder: cannot read bin/tool.sh"
  echo "npm error Lifecycle script build:runtime failed"
  exit 1
fi
root="$(git rev-parse --show-toplevel)" || exit 1
marker="$root/packages/create-egregore/runtime/codex/stub-build.txt"
mkdir -p "${marker%/*}"
: > "$marker.tmp"
while IFS= read -r file; do
  [ -f "$root/$file" ] || { echo "ENOENT: $file" >&2; rm -f "$marker.tmp"; exit 1; }
  printf '%s %s\n' "$(git -C "$root" hash-object -- "$file")" "$file" >> "$marker.tmp"
done < <(git -C "$root" ls-files -- bin egregore_runtime AGENTS.md CLAUDE.md .claude/skills .codex .pi .prime docs/spirit-discovery.md)
mv "$marker.tmp" "$marker"
STUB
cat > "$TMP/stub/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
  "pr list") echo '[]' ;;
  "pr create") echo "https://example.invalid/repo/pull/7" ;;
  "pr ready") exit 0 ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$TMP/stub/npm" "$TMP/stub/gh"

# One seed on develop, pushed to a bare origin; every case clones it fresh.
SEED="$TMP/seed"
git init -q -b develop "$SEED"
mkdir -p "$SEED/bin/lib" "$SEED/docs" "$SEED/packages/create-egregore" "$SEED/.claude/skills/demo"
cp "$AGENT_SH" "$SCRIPT_DIR/bin/node-run.sh" "$SEED/bin/"
for lib in config.sh scratch.sh git-message.sh noncode.sh; do
  cp "$SCRIPT_DIR/bin/lib/$lib" "$SEED/bin/lib/"
done
cat > "$SEED/bin/codex-sync-skills.sh" <<'STUB'
#!/usr/bin/env bash
# Stands in for the Codex skill sync: records the call, then writes one adapter
# per .claude/skills source and names each one it changed.
root="$(cd "$(dirname "$0")/.." && pwd)"
printf 'codex-sync\n' >> "$CALLS_LOG"
for source in "$root"/.claude/skills/*/SKILL.md; do
  name="${source%/SKILL.md}"
  name="${name##*/}"
  target="$root/.codex/skills/$name/SKILL.md"
  want="adapter for $name from $(git -C "$root" hash-object -- "$source")"
  [ "$(cat "$target" 2>/dev/null)" = "$want" ] && continue
  mkdir -p "${target%/*}"
  printf '%s\n' "$want" > "$target"
  echo "generated adapter: $name"
done
echo "codex skills synced"
STUB
cat > "$SEED/bin/codex-render-spec.mjs" <<'STUB'
// Stands in for the Codex spec render: records the call, then renders
// AGENTS.md and a manifest whose hand-written (replace) and kept sections
// are both hashed from CLAUDE.md.
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
fs.appendFileSync(process.env.CALLS_LOG, "codex-render\n");
if (process.env.RENDER_FAIL === "codex") {
  console.log("codex-render-spec: reading CLAUDE.md");
  console.error('codex-render-spec: no rule for CLAUDE.md section "Fixture"');
  process.exit(1);
}
const source = fs.readFileSync(path.join(root, "CLAUDE.md"), "utf8");
const sourceHash = crypto.createHash("sha256").update(source).digest("hex").slice(0, 12);
const sections = [
  { section: "Rules", action: "replace", sourceHash },
  { section: "Voice", action: "keep", sourceHash },
];
fs.writeFileSync(path.join(root, "AGENTS.md"), `# Agents\n\n${source}`);
fs.mkdirSync(path.join(root, ".codex"), { recursive: true });
fs.writeFileSync(path.join(root, ".codex/spec-manifest.json"), `${JSON.stringify({ sections }, null, 2)}\n`);
console.log("codex spec rendered");
STUB
cat > "$SEED/bin/pi-render-spec.mjs" <<'STUB'
// Stands in for the Pi and Prime spec renders: records the call, then renders
// the runtime's appendix from AGENTS.md.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
const self = fileURLToPath(import.meta.url);
const root = path.resolve(path.dirname(self), "..");
const runtime = path.basename(self).split("-")[0];
fs.appendFileSync(process.env.CALLS_LOG, `${runtime}-render\n`);
const dir = path.join(root, runtime === "pi" ? ".pi" : ".prime/agent");
const agents = fs.readFileSync(path.join(root, "AGENTS.md"), "utf8");
fs.mkdirSync(dir, { recursive: true });
fs.writeFileSync(path.join(dir, "APPEND_SYSTEM.md"), `# ${runtime}\n\n${agents}`);
fs.writeFileSync(path.join(dir, "spec-manifest.json"), `${JSON.stringify({ bytes: agents.length })}\n`);
console.log(`${runtime} spec rendered`);
STUB
cp "$SEED/bin/pi-render-spec.mjs" "$SEED/bin/prime-render-spec.mjs"
printf '#!/usr/bin/env bash\necho tool\n' > "$SEED/bin/tool.sh"
printf '#!/usr/bin/env bash\necho old\n' > "$SEED/bin/old-tool.sh"
printf '# Notes\n' > "$SEED/docs/notes.md"
printf '# Spirit discovery\n\nInspect installed capabilities.\n' > "$SEED/docs/spirit-discovery.md"
printf '# Egregore\n\n## Rules\n\nWork in a branch.\n' > "$SEED/CLAUDE.md"
printf -- '---\nname: demo\ndescription: A demo skill.\n---\n\n# Demo\n' > "$SEED/.claude/skills/demo/SKILL.md"
printf '%s\n' '{"base_branch":"develop","mode":"local"}' > "$SEED/egregore.json"
# If the real npm ever ran here, this script would fail the save loudly.
printf '%s\n' '{"name":"create-egregore","private":true,"scripts":{"build:runtime":"exit 97"}}' \
  > "$SEED/packages/create-egregore/package.json"
printf '.egregore-session-id\n' > "$SEED/.gitignore"
export CALLS_LOG="$TMP/seed.calls"
bash "$SEED/bin/codex-sync-skills.sh" > /dev/null
for spec in codex pi prime; do
  bash "$SEED/bin/node-run.sh" "$SEED/bin/$spec-render-spec.mjs" > /dev/null || { echo "fixture: $spec render failed"; exit 1; }
done
git -C "$SEED" add -A
(cd "$SEED/packages/create-egregore" && NPM_LOG="$TMP/seed.npm.log" "$TMP/stub/npm" run build:runtime) \
  || { echo "fixture: stub build failed"; exit 1; }
git -C "$SEED" add -A
git -C "$SEED" commit -q -m "test: seed the bundle fixture"
git init -q --bare -b develop "$TMP/origin.git"
git -C "$SEED" remote add origin "$TMP/origin.git"
git -C "$SEED" push -q origin develop

# new_case NAME: a fresh clone on task branch dev/tester/NAME, held in $REPO.
new_case() {
  REPO="$TMP/$1"
  git clone -q "$TMP/origin.git" "$REPO" 2>/dev/null
  git -C "$REPO" checkout -q --no-track -b "dev/tester/$1" origin/develop
  printf 'test-session\n' > "$REPO/.egregore-session-id"
}

# save ARGS...: the bridge's save in $REPO, stubs first on PATH. Output lands in
# $REPO.out and $REPO.err; generator calls in $REPO.calls, npm and gh detail
# in $REPO.npm and $REPO.gh.
save() {
  PATH="$TMP/stub:$PATH" NPM_LOG="$REPO.npm" GH_LOG="$REPO.gh" CALLS_LOG="$REPO.calls" \
    NPM_FAIL="$NPM_FAIL" RENDER_FAIL="$RENDER_FAIL" \
    bash "$REPO/bin/agent.sh" save "$@" > "$REPO.out" 2> "$REPO.err"
}

npm_calls() { [ -f "$REPO.npm" ] && wc -l < "$REPO.npm" | tr -d ' ' || echo 0; }
calls() { [ -f "$REPO.calls" ] && tr '\n' ' ' < "$REPO.calls" | sed 's/ $//'; }
has_line() { grep -Fxq -- "$1" "$2"; }
has_lines() { local file="$1" line; shift; for line in "$@"; do has_line "$line" "$file" || return 1; done; }
show() { tr '\n' ' ' < "$1"; }
files_in_head() { git -C "$REPO" show --no-renames --name-status --format= HEAD | tr '\t' ' ' > "$REPO.files"; }

echo "Testing: bin/agent.sh save regenerates the derived views and bundles"
echo

echo "── a change under bin/ rebuilds and commits the bundles ──"
new_case bin-change
printf '#!/usr/bin/env bash\necho new\n' > "$REPO/bin/new-tool.sh"
rm "$REPO/bin/old-tool.sh"
save --message 'feat(tool): add the new tool' --no-pr
rc=$?
if [ "$rc" -eq 0 ] && has_lines "$REPO.out" "codex skills: current" "specs: current" \
     "bundles: rebuilt (1 file changed)"; then
  pass "save prints the rebuilt receipt, with the views current"
else
  fail "save did not report a bundle-only rebuild" "rc=$rc; $(show "$REPO.out") $(show "$REPO.err")"
fi
if [ "$(calls)" = "npm" ] && grep -Eq '/packages/create-egregore\|run build:runtime$' "$REPO.npm"; then
  pass "only npm runs, once, as build:runtime from packages/create-egregore"
else
  fail "the generators ran other than expected" "calls: $(calls); npm: $(cat "$REPO.npm" 2>/dev/null)"
fi
if git -C "$REPO" show HEAD:"$MARKER" 2>/dev/null | grep -q ' bin/new-tool.sh$' &&
   ! git -C "$REPO" show HEAD:"$MARKER" | grep -q ' bin/old-tool.sh$'; then
  pass "the marker in the commit lists the new file and drops the deleted one"
else
  fail "the committed marker does not reflect the new and deleted inputs"
fi
files_in_head
if [ "$(git -C "$REPO" log -1 --format=%s)" = "feat(tool): add the new tool" ] &&
   has_lines "$REPO.files" "M $MARKER" "A bin/new-tool.sh" "D bin/old-tool.sh" &&
   [ -z "$(git -C "$REPO" status --porcelain)" ]; then
  pass "the regenerated marker rides in the caller's commit; the tree ends clean"
else
  fail "the caller's commit does not carry the work and the bundles together" \
    "$(git -C "$REPO" log -1 --format=%s) | $(show "$REPO.files") | $(git -C "$REPO" status --porcelain | tr '\n' ' ')"
fi
if [ -n "$(git -C "$REPO" ls-remote --heads origin dev/tester/bin-change)" ]; then
  pass "the branch is pushed"
else
  fail "the branch was not pushed"
fi
save --message 'feat(tool): add the new tool' --no-pr
rc=$?
if [ "$rc" -eq 0 ] && [ "$(calls)" = "npm npm" ] &&
   has_lines "$REPO.out" "codex skills: current" "specs: current" "bundles: current" "commit: false"; then
  pass "a second save rebuilds to the same bundles and commits nothing"
else
  fail "a repeated save was not idempotent" "rc=$rc; calls: $(calls); $(show "$REPO.out")"
fi

echo
echo "── a markdown change outside the inputs runs nothing ──"
new_case notes-only
printf '# Notes\n\nA new line.\n' > "$REPO/docs/notes.md"
save --message 'docs(notes): add a line' --no-pr
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$(calls)" ] &&
   has_lines "$REPO.out" "codex skills: current" "specs: current" "bundles: current"; then
  pass "every step reports current and no generator runs"
else
  fail "a non-input change reached a generator" "rc=$rc; calls: $(calls); $(show "$REPO.out")"
fi
if [ "$(git -C "$REPO" log -1 --format=%s)" = "docs(notes): add a line" ] &&
   [ "$(git -C "$REPO" show --name-only --format= HEAD)" = "docs/notes.md" ]; then
  pass "the commit carries only the note, under the caller's message"
else
  fail "the note commit is wrong" "$(git -C "$REPO" show --stat --format=%s HEAD)"
fi

echo
echo "── a shipped discovery-guide edit rebuilds the bundles ──"
new_case discovery-guide
printf '# Spirit discovery\n\nInspect updated installed capabilities.\n' > "$REPO/docs/spirit-discovery.md"
save --message 'docs(discovery): clarify installed capabilities' --no-pr
rc=$?
guide_hash="$(git -C "$REPO" hash-object -- docs/spirit-discovery.md)"
if [ "$rc" -eq 0 ] && [ "$(calls)" = "npm" ] &&
   has_lines "$REPO.out" "codex skills: current" "specs: current" "bundles: rebuilt (1 file changed)" &&
   git -C "$REPO" show "HEAD:$MARKER" | grep -Fxq "$guide_hash docs/spirit-discovery.md"; then
  pass "a discovery-guide-only edit rebuilds and commits the current guide bytes"
else
  fail "the discovery guide shipped stale bytes" "rc=$rc; calls: $(calls); $(show "$REPO.out")"
fi
files_in_head
if has_lines "$REPO.files" "M docs/spirit-discovery.md" "M $MARKER" &&
   [ -z "$(git -C "$REPO" status --porcelain)" ]; then
  pass "the guide and regenerated bundle commit together with a clean tree"
else
  fail "the guide and bundle were not saved together" "$(show "$REPO.files")"
fi

echo
echo "── a skill edit syncs the Codex adapter, not the specs ──"
new_case skill-edit
printf -- '---\nname: demo\ndescription: A sharper demo skill.\n---\n\n# Demo\n' > "$REPO/.claude/skills/demo/SKILL.md"
save --message 'feat(demo): sharpen the demo skill' --no-pr
rc=$?
if [ "$rc" -eq 0 ] && [ "$(calls)" = "codex-sync npm" ] &&
   has_lines "$REPO.out" "codex skills: synced (1 file)" "specs: current" "bundles: rebuilt (1 file changed)"; then
  pass "the sync runs before the build; the renders, which never read skills, do not"
else
  fail "a skill edit ran the wrong generators" "rc=$rc; calls: $(calls); $(show "$REPO.out") $(show "$REPO.err")"
fi
files_in_head
if [ "$(git -C "$REPO" log -1 --format=%s)" = "feat(demo): sharpen the demo skill" ] &&
   has_lines "$REPO.files" "M .claude/skills/demo/SKILL.md" "M .codex/skills/demo/SKILL.md" "M $MARKER"; then
  pass "the source, its adapter and the bundle marker commit together"
else
  fail "the skill commit is missing its derived files" "$(show "$REPO.files")"
fi

echo
echo "── a CLAUDE.md edit renders the specs in order, not the sync ──"
new_case claude-edit
printf '# Egregore\n\n## Rules\n\nWork in a branch and save often.\n' > "$REPO/CLAUDE.md"
save --message 'docs(claude): tighten the branch rule' --no-pr
rc=$?
if [ "$rc" -eq 0 ] && [ "$(calls)" = "codex-render pi-render prime-render npm" ] &&
   has_lines "$REPO.out" "codex skills: current" "specs: rendered (codex, pi, prime)" \
     "bundles: rebuilt (1 file changed)"; then
  pass "Codex renders first, Pi and Prime follow its AGENTS.md, and the build comes last"
else
  fail "a CLAUDE.md edit ran the wrong generators or order" "rc=$rc; calls: $(calls); $(show "$REPO.out") $(show "$REPO.err")"
fi
if has_line "$REVIEW" "$REPO.out"; then
  pass "the hand-written Codex section whose source changed is named for review; the kept one is not"
else
  fail "the review line is missing or wrong" "$(show "$REPO.out")"
fi
files_in_head
if [ "$(git -C "$REPO" log -1 --format=%s)" = "docs(claude): tighten the branch rule" ] &&
   has_lines "$REPO.files" "M CLAUDE.md" "M AGENTS.md" "M .codex/spec-manifest.json" \
     "M .pi/APPEND_SYSTEM.md" "M .prime/agent/APPEND_SYSTEM.md" "M $MARKER"; then
  pass "the source, the three specs and the bundle marker commit together"
else
  fail "the CLAUDE.md commit is missing derived files" "$(show "$REPO.files")"
fi

echo
echo "── a failing step stops the save before any commit ──"
new_case build-fails
printf '#!/usr/bin/env bash\necho changed\n' > "$REPO/bin/tool.sh"
before="$(git -C "$REPO" rev-parse HEAD)"
NPM_FAIL=1
save --message 'fix(tool): change the tool' --no-pr
rc=$?
NPM_FAIL=0
if [ "$rc" -ne 0 ] && grep -Fq "builder: cannot read bin/tool.sh" "$REPO.err" &&
   grep -Fq "bundle rebuild failed" "$REPO.err"; then
  pass "a failed build exits non-zero with the build's last lines on stderr"
else
  fail "a failed build did not stop the save visibly" "rc=$rc; $(show "$REPO.err")"
fi
if [ "$(git -C "$REPO" rev-parse HEAD)" = "$before" ] &&
   [ -z "$(git -C "$REPO" ls-remote --heads origin dev/tester/build-fails)" ] &&
   ! grep -Fq "commit: true" "$REPO.out" &&
   [ "$(git -C "$REPO" status --porcelain)" = " M bin/tool.sh" ]; then
  pass "after a failed build nothing is committed or pushed, and the change stays"
else
  fail "the failed build left a commit, a push, or a changed tree" "$(git -C "$REPO" status --porcelain | tr '\n' ' ')"
fi
new_case render-fails
printf '# Egregore\n\n## Rules\n\nWork in a branch.\n\n## Fixture\n\nNew.\n' > "$REPO/CLAUDE.md"
before="$(git -C "$REPO" rev-parse HEAD)"
RENDER_FAIL=codex
save --message 'docs(claude): add a section' --no-pr
rc=$?
RENDER_FAIL=""
if [ "$rc" -ne 0 ] && [ "$(calls)" = "codex-render" ] &&
   grep -Fq 'no rule for CLAUDE.md section "Fixture"' "$REPO.err" && grep -Fq "codex spec render failed" "$REPO.err"; then
  pass "a failed render stops before Pi, Prime and the build, with its last lines on stderr"
else
  fail "a failed render did not stop the save" "rc=$rc; calls: $(calls); $(show "$REPO.err")"
fi
if [ "$(git -C "$REPO" rev-parse HEAD)" = "$before" ] &&
   [ -z "$(git -C "$REPO" ls-remote --heads origin dev/tester/render-fails)" ] &&
   [ "$(git -C "$REPO" status --porcelain)" = " M CLAUDE.md" ]; then
  pass "after a failed render nothing is committed or pushed, and the change stays"
else
  fail "the failed render left a commit, a push, or a changed tree" "$(git -C "$REPO" status --porcelain | tr '\n' ' ')"
fi

echo
echo "── a clean tree whose branch carries an input change ──"
new_case branch-ahead
printf '#!/usr/bin/env bash\necho mended\n' > "$REPO/bin/tool.sh"
git -C "$REPO" commit -qam "fix(tool): mend the tool"
save --message 'fix(tool): mend the tool' --pr-body 'fixture body'
rc=$?
if [ "$rc" -eq 0 ] && [ "$(calls)" = "npm" ] && has_line "bundles: rebuilt (1 file changed)" "$REPO.out"; then
  pass "the branch diff alone triggers the rebuild"
else
  fail "a clean tree with a bin/ change ahead was not rebuilt" "rc=$rc; calls: $(calls); $(show "$REPO.out") $(show "$REPO.err")"
fi
if [ "$(git -C "$REPO" log -1 --format=%s)" = "chore(bundles): regenerate runtime bundles" ] &&
   git -C "$REPO" log -1 --format=%B | grep -Fxq "Egregore-Session: test-session" &&
   [ "$(git -C "$REPO" show --name-only --format= HEAD)" = "$MARKER" ] &&
   [ "$(git -C "$REPO" log -1 --skip=1 --format=%s)" = "fix(tool): mend the tool" ]; then
  pass "the rebuild commits alone as chore(bundles) with the session trailer"
else
  fail "the bundle-only commit is wrong" "$(git -C "$REPO" log -2 --format='%s | %b' | tr '\n' ' ')"
fi
if grep -Fq -- "--title fix(tool): mend the tool" "$REPO.gh" 2>/dev/null &&
   [ -n "$(git -C "$REPO" ls-remote --heads origin dev/tester/branch-ahead)" ]; then
  pass "the PR keeps the caller's title and the branch is pushed"
else
  fail "the PR title or push is wrong" "$(cat "$REPO.gh" 2>/dev/null)"
fi
new_case claude-ahead
printf '# Egregore\n\n## Rules\n\nWork in a branch, always.\n' > "$REPO/CLAUDE.md"
git -C "$REPO" commit -qam "docs(claude): restate the branch rule"
save --message 'docs(claude): restate the branch rule' --no-pr
rc=$?
if [ "$rc" -eq 0 ] && [ "$(calls)" = "codex-render pi-render prime-render npm" ] &&
   [ "$(git -C "$REPO" log -1 --format=%s)" = "chore(bundles): regenerate specs and runtime bundles" ]; then
  pass "a committed CLAUDE.md change renders on save and commits under a subject naming the specs"
else
  fail "a CLAUDE.md change ahead of origin was not rendered" "rc=$rc; calls: $(calls); $(git -C "$REPO" log -1 --format=%s)"
fi

echo
echo "── instances without the generators ──"
new_case no-view-scripts
git -C "$REPO" rm -q bin/codex-sync-skills.sh bin/codex-render-spec.mjs bin/pi-render-spec.mjs bin/prime-render-spec.mjs
git -C "$REPO" commit -qm "test: drop the view generators"
printf '#!/usr/bin/env bash\necho local\n' > "$REPO/bin/tool.sh"
save --message 'fix(tool): adjust the tool' --no-pr
rc=$?
if [ "$rc" -eq 0 ] && [ "$(calls)" = "npm" ] &&
   has_lines "$REPO.out" "codex skills: not applicable" "specs: not applicable" "bundles: rebuilt (1 file changed)"; then
  pass "a missing sync or render script is not applicable, and the build still runs"
else
  fail "missing view scripts were not reported as not applicable" "rc=$rc; calls: $(calls); $(show "$REPO.out") $(show "$REPO.err")"
fi
new_case installed
git -C "$REPO" rm -q packages/create-egregore/package.json
git -C "$REPO" commit -qm "test: drop the builders"
printf '# Egregore\n\n## Rules\n\nLocal edit.\n' > "$REPO/CLAUDE.md"
printf '#!/usr/bin/env bash\necho local\n' > "$REPO/bin/tool.sh"
save --message 'fix(tool): adjust the tool' --no-pr
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$(calls)" ] &&
   has_lines "$REPO.out" "codex skills: not applicable" "specs: not applicable" "bundles: not applicable" &&
   [ "$(git -C "$REPO" log -1 --format=%s)" = "fix(tool): adjust the tool" ]; then
  pass "an instance without the builders reports every step not applicable and commits as before"
else
  fail "an instance without builders ran a generator" "rc=$rc; calls: $(calls); $(show "$REPO.out") $(show "$REPO.err")"
fi

echo
echo "── the watched inputs cover every file the real builders ship ──"
if [ ! -f "$SCRIPT_DIR/packages/create-egregore/runtime/codex/manifest.json" ]; then
  echo "  – skipped: this checkout carries no runtime bundles"
else
  eval "$(sed -n '/^derivation_inputs() {$/,/^}$/p' "$AGENT_SH")"
  if ! type derivation_inputs >/dev/null 2>&1; then
    fail "bin/agent.sh no longer defines derivation_inputs"
  else
    inputs=()
    while IFS= read -r path; do inputs+=("$path"); done < <(derivation_inputs bundles)
    git -C "$SCRIPT_DIR" ls-files -- "${inputs[@]}" | LC_ALL=C sort -u > "$TMP/watched"
    # Settings and the four capability snapshots are generated in the bundle,
    # not copied from same-named source files. Their builders, catalog and
    # snapshot owner live under the watched inputs; do not exclude other files.
    {
      for bundle in codex claude pi prime; do
        jq -r '.files[]' "$SCRIPT_DIR/packages/create-egregore/runtime/$bundle/manifest.json"
      done
      [ -f "$SCRIPT_DIR/api/assets/connect-runtime-pack.json" ] &&
        jq -r '.files[].path' "$SCRIPT_DIR/api/assets/connect-runtime-pack.json"
    } | grep -Ev '^(\.claude/settings\.json|bin/data/capabilities/(claude|codex|pi|prime)\.json)$' \
      | LC_ALL=C sort -u > "$TMP/shipped"
    unwatched="$(LC_ALL=C comm -23 "$TMP/shipped" "$TMP/watched")"
    if [ -s "$TMP/shipped" ] && [ -z "$unwatched" ]; then
      pass "every shipped file ($(wc -l < "$TMP/shipped" | tr -d ' ')) comes from a watched input"
    else
      fail "shipped files the save does not watch" "$(printf '%s\n' "$unwatched" | head -5 | tr '\n' ' ')"
    fi
  fi
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
