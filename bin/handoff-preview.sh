#!/usr/bin/env bash
set -euo pipefail

# Private preview/approval bridge for internal handoffs. Canonical Markdown is
# supplied once during preview; approval references an opaque, single-use token.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STORE_ROOT="${EGREGORE_HANDOFF_PREVIEW_DIR:-${TMPDIR:-/tmp}/egregore-handoff-previews}"
MAX_AGE_SECONDS="${EGREGORE_HANDOFF_PREVIEW_MAX_AGE:-21600}"

usage() {
  cat >&2 <<'EOF'
usage:
  bash bin/handoff-preview.sh preview --author HANDLE --recipient HANDLE \
    --topic TOPIC --intent action|feedback|fyi \
    --content-mode supplied|generated [--composed SPEC.json] < handoff.md
  bash bin/handoff-preview.sh approve TOKEN
EOF
}

sha256_file() {
  if command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$1" | awk '{print $NF}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

new_token() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16
  else
    printf '%s' "$(date +%s)-$$-${RANDOM:-0}" | sha256sum | awk '{print substr($1,1,32)}'
  fi
}

validate_token() {
  [[ "$1" =~ ^[a-f0-9]{32}$ ]] || {
    echo "handoff preview token is invalid" >&2
    exit 2
  }
}

preview() {
  local author="" recipient="" topic="" intent="" content_mode="" composed="" composed_content=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --author) author="${2:-}"; shift 2 ;;
      --recipient) recipient="${2:-}"; shift 2 ;;
      --topic) topic="${2:-}"; shift 2 ;;
      --intent) intent="${2:-}"; shift 2 ;;
      --content-mode) content_mode="${2:-}"; shift 2 ;;
      --composed) composed="${2:-}"; shift 2 ;;
      *) echo "unknown preview option: $1" >&2; usage; exit 2 ;;
    esac
  done

  [ -n "$author" ] || { echo "handoff preview requires --author" >&2; exit 2; }
  [ -n "$topic" ] || { echo "handoff preview requires --topic" >&2; exit 2; }
  case "$intent" in action|feedback|fyi) ;; *) echo "invalid handoff intent" >&2; exit 2 ;; esac
  case "$content_mode" in supplied|generated) ;; *) echo "invalid handoff content mode" >&2; exit 2 ;; esac
  if [ -n "$composed" ]; then
    # A composed spec (for example a staircase) is a presentation map over the
    # canonical Markdown. It rides the same private record and is judged by the
    # same fidelity gate; it never replaces the Markdown as the record.
    [ "$content_mode" = "generated" ] || { echo "--composed requires --content-mode generated" >&2; exit 2; }
    [ -s "$composed" ] || { echo "handoff preview --composed file is missing or empty" >&2; exit 2; }
    # The suffix preserves trailing newlines through command substitution.
    composed_content="$(cat "$composed" && printf '.')"
    composed_content="${composed_content%.}"
    # publish-artifact reads the composed spec again, so the session sweep owns it.
    printf '%s' "$composed_content" | jq -e . >/dev/null 2>&1 || { echo "handoff preview --composed file is not JSON" >&2; exit 2; }
  fi

  umask 077
  mkdir -p "$STORE_ROOT"
  chmod 700 "$STORE_ROOT"

  local token content_file metadata_file spec_file digest spec_digest
  token="$(new_token)"
  validate_token "$token"
  content_file="$STORE_ROOT/$token.md"
  metadata_file="$STORE_ROOT/$token.json"
  spec_file="$STORE_ROOT/$token.spec.json"
  cat > "$content_file"
  [ -s "$content_file" ] || {
    rm -f "$content_file"
    echo "handoff preview input is empty" >&2
    exit 2
  }
  digest="$(sha256_file "$content_file")"
  spec_digest=""
  if [ -n "$composed" ]; then
    printf '%s' "$composed_content" > "$spec_file"
    spec_digest="$(sha256_file "$spec_file")"
  fi
  jq -n \
    --arg author "$author" \
    --arg recipient "$recipient" \
    --arg topic "$topic" \
    --arg intent "$intent" \
    --arg contentMode "$content_mode" \
    --arg digest "$digest" \
    --arg specDigest "$spec_digest" \
    --argjson createdAt "$(date +%s)" \
    '{author:$author,recipient:$recipient,topic:$topic,intent:$intent,contentMode:$contentMode,digest:$digest,specDigest:$specDigest,createdAt:$createdAt}' \
    > "$metadata_file"

  local render_ok=0
  if [ -n "$composed" ]; then
    if bash "$ROOT/bin/node-run.sh" \
      "$ROOT/packages/egregore-artifacts/bin/cli.js" composed "$spec_file" \
      --source "$content_file" --verify-fidelity; then
      render_ok=1
    fi
  elif bash "$ROOT/bin/node-run.sh" \
    "$ROOT/packages/egregore-artifacts/bin/cli.js" handoff "$content_file" \
    --verify-fidelity; then
    render_ok=1
  fi
  if [ "$render_ok" != "1" ]; then
    rm -f "$content_file" "$metadata_file" "$spec_file"
    exit 1
  fi

  printf 'HANDOFF_PREVIEW_TOKEN=%s\n' "$token"
}

approve() {
  [ $# -eq 1 ] || { usage; exit 2; }
  local token="$1"
  validate_token "$token"

  local content_file="$STORE_ROOT/$token.md"
  local metadata_file="$STORE_ROOT/$token.json"
  local lock_dir="$STORE_ROOT/$token.approving"
  [ -f "$content_file" ] && [ -f "$metadata_file" ] || {
    echo "handoff preview is missing, expired, or already used" >&2
    exit 1
  }
  if ! mkdir "$lock_dir" 2>/dev/null; then
    echo "handoff preview approval is already running" >&2
    exit 1
  fi

  local expected_digest actual_digest created_at now age
  expected_digest="$(jq -er '.digest' "$metadata_file")"
  actual_digest="$(sha256_file "$content_file")"
  if [ "$expected_digest" != "$actual_digest" ]; then
    rmdir "$lock_dir" 2>/dev/null || true
    echo "handoff preview content changed after approval was requested" >&2
    exit 1
  fi
  created_at="$(jq -er '.createdAt' "$metadata_file")"
  now="$(date +%s)"
  age=$((now - created_at))
  if [ "$age" -lt 0 ] || [ "$age" -gt "$MAX_AGE_SECONDS" ]; then
    rmdir "$lock_dir" 2>/dev/null || true
    echo "handoff preview expired; render a fresh preview" >&2
    exit 1
  fi

  local author recipient topic intent content_mode spec_digest
  author="$(jq -er '.author' "$metadata_file")"
  recipient="$(jq -er '.recipient' "$metadata_file")"
  topic="$(jq -er '.topic' "$metadata_file")"
  intent="$(jq -er '.intent' "$metadata_file")"
  content_mode="$(jq -er '.contentMode' "$metadata_file")"
  spec_digest="$(jq -r '.specDigest // ""' "$metadata_file")"

  # A previewed composed spec is bound to the same token and the same digest
  # discipline as the Markdown: approval sends exactly the previewed bytes.
  local spec_file="$STORE_ROOT/$token.spec.json"
  if [ -n "$spec_digest" ]; then
    if [ ! -f "$spec_file" ] || [ "$(sha256_file "$spec_file")" != "$spec_digest" ]; then
      rmdir "$lock_dir" 2>/dev/null || true
      echo "handoff preview composed spec is missing or changed after approval was requested" >&2
      exit 1
    fi
  else
    spec_file=""
  fi

  local result_tmp
  result_tmp="$(mktemp -d -t egregore-handoff-result-XXXXXX)"
  local args=(
    capture --mode addressed --author "$author" --topic "$topic"
    --intent "$intent" --content-mode "$content_mode"
  )
  [ -z "$recipient" ] || args+=(--recipient "$recipient")
  [ -z "$spec_file" ] || args+=(--composed "$spec_file")

  if ! TMPDIR="$result_tmp" bash "$ROOT/bin/artifact-writeback.sh" "${args[@]}" \
    < "$content_file"; then
    rmdir "$lock_dir" 2>/dev/null || true
    exit 1
  fi

  # Persist the composed spec beside the canonical record so the face can be
  # re-rendered or shared later from memory alone. The record is already
  # canonical at this point; a spec persistence failure is reported, not
  # retried, so the approval can never write the record twice.
  if [ -n "$spec_file" ]; then
    local record_abs record_rel spec_rel
    record_abs="$(jq -r '.absFile // empty' "$result_tmp/capture-run-result.json" 2>/dev/null || true)"
    record_rel="${record_abs#"$ROOT/"}"
    case "$record_rel" in
      memory/*.md)
        spec_rel="${record_rel%.md}.staircase.json"
        if ! bash "$ROOT/bin/artifact-writeback.sh" create \
          --path "$spec_rel" --input "$spec_file" >/dev/null; then
          echo "warning: the canonical record was written but its composed spec could not be persisted at $spec_rel" >&2
        fi
        ;;
      *)
        echo "warning: the canonical record path is not under memory/; the composed spec was not persisted" >&2
        ;;
    esac
  fi

  # Consume the approved token before rendering. A renderer failure must not
  # make a successful canonical write eligible for accidental replay.
  mv "$content_file" "$result_tmp/approved-handoff.md"
  mv "$metadata_file" "$result_tmp/approved-handoff.json"
  [ -z "$spec_file" ] || mv "$spec_file" "$result_tmp/approved-handoff.staircase.json"
  rmdir "$lock_dir" 2>/dev/null || true
  bash "$ROOT/bin/render-card.sh" \
    --result "$result_tmp/capture-run-result.json"
}

case "${1:-}" in
  preview) shift; preview "$@" ;;
  approve) shift; approve "$@" ;;
  *) usage; exit 2 ;;
esac
