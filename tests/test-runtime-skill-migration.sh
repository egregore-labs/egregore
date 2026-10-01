#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

node "$ROOT_DIR/bin/capability-distribution.mjs" runtime-skill-audit \
  --root "$ROOT_DIR" --strict-contract >/dev/null

for skill in commit push pull pr sync-repos; do
  file="$ROOT_DIR/.claude/skills/$skill/SKILL.md"
  if grep -Eq '## Loom routing|bin/loom\.sh route' "$file"; then
    echo "$skill must not route deterministic Git work through another model" >&2
    exit 1
  fi
done

for skill in audit character-v4 deep-reflect harvest quest-suggest reflect \
  session-view tutorial the-spiral view; do
  file="$ROOT_DIR/.claude/skills/$skill/SKILL.md"
  if ! grep -Fq 'EGREGORE_ORG_CONTEXT_V1' "$file"; then
    echo "$skill must reuse compiled Runtime context" >&2
    exit 1
  fi
done

if grep -Eq '^[[:space:]]*bash[[:space:]]+bin/(graph|graph-op|graph-batch)\.sh' \
  "$ROOT_DIR/.claude/skills/character-v4/SKILL.md"; then
  echo "character must consume one canonical snapshot, not graph queries" >&2
  exit 1
fi

if grep -Eq '(^|[[:space:]])(ls|find)[[:space:]]+memory/' \
  "$ROOT_DIR/.claude/skills/view/SKILL.md"; then
  echo "view must resolve canonical sources through Runtime query/open" >&2
  exit 1
fi
if grep -Fq 'publishes to a stable URL' "$ROOT_DIR/.claude/skills/view/SKILL.md" || \
   grep -Fq 'on every invocation' "$ROOT_DIR/.claude/skills/view/SKILL.md"; then
  echo "view must not publish without an explicit SHARE action" >&2
  exit 1
fi

if grep -Fqi 'activity auto-syncs' "$ROOT_DIR/.claude/skills/pull/SKILL.md"; then
  echo "pull must not claim that read-only activity synchronizes repositories" >&2
  exit 1
fi

for skill in ask answer; do
  file="$ROOT_DIR/.claude/skills/$skill/SKILL.md"
  if grep -Eq '^[[:space:]]*bash[[:space:]]+bin/(graph|graph-op|graph-batch)\.sh' "$file"; then
    echo "$skill must use canonical question state, not graph authority" >&2
    exit 1
  fi
  grep -Fq 'Markdown/Git is authoritative in every mode' "$file" || {
    echo "$skill must declare one cross-mode canonical authority" >&2
    exit 1
  }
done

question_bridge="$(awk '/^cmd_ask\(\)/,/^cmd_search\(\)/' "$ROOT_DIR/bin/agent.sh")"
if ! grep -Fq 'bin/question.sh' <<<"$question_bridge" || \
   ! grep -Fq 'self.runtime.write_document' "$ROOT_DIR/egregore_runtime/questions.py"; then
  echo "ask/answer must enter Runtime canonical writeback" >&2
  exit 1
fi

todo_skill="$ROOT_DIR/.claude/skills/todo/SKILL.md"
grep -Fq 'bash bin/todo.sh' "$todo_skill" || {
  echo "todo must use the canonical Runtime adapter" >&2
  exit 1
}
if grep -Eq '^[[:space:]]*bash[[:space:]]+bin/(graph|graph-op|graph-batch)\.sh' "$todo_skill"; then
  echo "todo must not use graph state as a mode-specific authority" >&2
  exit 1
fi

grep -Fq '"$SCRIPT_DIR/.claude/skills"' "$ROOT_DIR/bin/test-changes.sh" || {
  echo "test --all must include the actual source skill directory" >&2
  exit 1
}
test_skill="$ROOT_DIR/.claude/skills/test/SKILL.md"
grep -Fq 'runtime-skill-audit' "$test_skill" || {
  echo "test must run the Runtime architectural ratchet" >&2
  exit 1
}
if grep -Eq '^[[:space:]]*bash[[:space:]]+bin/graph\.sh' "$test_skill"; then
  echo "test must not require a live graph on its default path" >&2
  exit 1
fi

qa_skill="$ROOT_DIR/.claude/skills/qa/SKILL.md"
grep -Fq 'runtime-skill-audit' "$qa_skill" || {
  echo "qa must include the Runtime architectural ratchet" >&2
  exit 1
}
if grep -Eq 'bin/(graph|graph-op|graph-batch)\.sh' "$qa_skill"; then
  echo "qa must not execute graph mechanics from its default path" >&2
  exit 1
fi

update_skill="$ROOT_DIR/.claude/skills/update/SKILL.md"
for marker in '.prime/' 'prime-render-spec.mjs'; do
  grep -Fq "$marker" "$update_skill" || {
    echo "update must keep Prime aligned: missing $marker" >&2
    exit 1
  }
done

me_skill="$ROOT_DIR/.claude/skills/me/SKILL.md"
for marker in AccountIdentity ActorIdentity OrgMembership; do
  grep -Fq "$marker" "$me_skill" || {
    echo "me must preserve provider-independent identity separation: missing $marker" >&2
    exit 1
  }
done
if grep -Fq 'GitHub numeric id is durable' "$me_skill" || \
   grep -Eq 'bin/(graph|graph-op|graph-batch)\.sh' "$me_skill"; then
  echo "me must not define identity by GitHub or manage projections directly" >&2
  exit 1
fi

for announce_skill in "$ROOT_DIR/.claude/skills/announce/SKILL.md"; do
  grep -Fq 'Notification consent and publication consent are separate' \
    "$announce_skill" || grep -Fq 'Notification and publication consent are separate' \
    "$announce_skill" || {
      echo "announce must separate publication from notification consent" >&2
      exit 1
    }
  if grep -Fq 'bash bin/publish-artifact.sh' "$announce_skill"; then
    echo "announce must not publish an artifact before exact SHARE approval" >&2
    exit 1
  fi
done

echo "PASS: Runtime skill migration contracts"
