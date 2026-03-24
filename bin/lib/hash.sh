#!/bin/bash
# Cross-platform hash helpers — sourced by scripts that need hashing.

# Compute MD5 hash of a string (macOS + Linux compatible)
_md5() {
  local input="$1"
  echo -n "$input" | md5 2>/dev/null || echo -n "$input" | md5sum 2>/dev/null | cut -d' ' -f1
}

# Compute project hash (used for per-instance file isolation)
_proj_hash() {
  _md5 "${SCRIPT_DIR:-$PWD}"
}
