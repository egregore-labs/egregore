#!/bin/bash
# artifact-id.sh — Deterministic artifact IDs for memory files.
#
# Emits `{prefix}-{12 hex}` where prefix is derived from the file extension
# (m = .md, h = .html) and the hex is the first 12 chars of sha256(canonical_path).
#
# Kept in parity with packages/egregore-artifacts/lib/artifact-id.js — both MUST
# produce identical output for the same input. Any change here requires an
# equivalent change there (and a passing parity test in test/artifact-id.test.js).

_artifact_id_sha256() {
  local input="$1"
  printf '%s' "$input" | shasum -a 256 2>/dev/null | cut -d' ' -f1 \
    || printf '%s' "$input" | sha256sum 2>/dev/null | cut -d' ' -f1
}

# artifact_id_from_path <path>
# Returns the deterministic artifact id for a repo-relative memory path, or
# empty (exit 1) if the extension is unsupported.
artifact_id_from_path() {
  local raw="$1"
  [ -n "$raw" ] || return 1

  local canonical
  canonical="${raw#./}"
  canonical="$(printf '%s' "$canonical" | sed 's|/\{2,\}|/|g')"

  # Extension match is case-insensitive to keep parity with the JS renderer
  # (`extension()` in artifact-id.js lowercases before lookup). The canonical
  # path itself is hashed verbatim — only the extension lookup is case-folded.
  local ext_lower
  ext_lower="$(printf '%s' "${canonical##*.}" | tr '[:upper:]' '[:lower:]')"

  local prefix=""
  case "$ext_lower" in
    md) prefix="m" ;;
    html) prefix="h" ;;
    *) return 1 ;;
  esac

  local hash
  hash="$(_artifact_id_sha256 "$canonical")"
  [ -n "$hash" ] || return 1

  printf '%s-%s' "$prefix" "${hash:0:12}"
}
