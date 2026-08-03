#!/usr/bin/env bash
# Locate and scrub Claude Code transcripts for /issue attachments.
#
# Fail-soft contract: missing inputs print a clear message and exit nonzero.
# The scrubber never sources .env and never passes .env values as shell args.

SCRIPT_DIR="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)"
REPO_ROOT="${TRANSCRIPT_ATTACH_REPO_ROOT:-$SCRIPT_DIR}"
CLEANUP_PATHS=""
PUBLISH_CLEANUP_PATHS=""

add_cleanup_path() {
  CLEANUP_PATHS="${CLEANUP_PATHS}${1}"$'\n'
}

add_publish_cleanup_path() {
  PUBLISH_CLEANUP_PATHS="${PUBLISH_CLEANUP_PATHS}${1}"$'\n'
}

cleanup_paths() {
  local path=""
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    rm -rf "$path" 2>/dev/null || true
  done <<EOF
$CLEANUP_PATHS
EOF
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    rm -f "$path" 2>/dev/null || true
  done <<EOF
$PUBLISH_CLEANUP_PATHS
EOF
}

cleanup_on_exit() {
  local status=$?
  cleanup_paths
  exit "$status"
}

trap cleanup_on_exit EXIT
trap 'exit 130' HUP INT TERM

usage() {
  cat >&2 <<'EOF'
Usage:
  transcript-attach.sh locate [N]
  transcript-attach.sh scrub <out_dir> <file>...
EOF
}

json_escape() {
  awk '
    BEGIN { ORS = "" }
    {
      if (NR > 1) printf "\\n"
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (c == "\\") printf "\\\\"
        else if (c == "\"") printf "\\\""
        else if (c == "\t") printf "\\t"
        else if (c == "\r") printf "\\r"
        else printf "%s", c
      }
    }
  '
}

munge_project_path() {
  printf '%s' "$1" | sed 's#[/.]#-#g'
}

file_mtime_epoch() {
  stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1" 2>/dev/null || printf '0'
}

file_size_bytes() {
  stat -f '%z' "$1" 2>/dev/null || stat -c '%s' "$1" 2>/dev/null || wc -c < "$1" 2>/dev/null | tr -d ' '
}

epoch_to_iso() {
  local epoch="$1"
  date -u -r "$epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || date -u -d "@$epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || printf '1970-01-01T00:00:00Z'
}

candidate_project_paths() {
  local cwd="$1"
  local main=""

  printf '%s\n' "$cwd"
  case "$cwd" in
    *"/.claude/worktrees/"*)
      main="${cwd%%/.claude/worktrees/*}"
      [ -n "$main" ] && [ "$main" != "$cwd" ] && printf '%s\n' "$main"
      ;;
  esac
}

cmd_locate() {
  local limit="${1:-5}"
  local projects_dir="${CLAUDE_PROJECTS_DIR:-}"
  local cwd=""
  local tmp=""
  local project_path=""
  local key=""
  local dir=""
  local file=""
  local epoch=""
  local size=""
  local count=0
  local idx=0

  case "$limit" in
    ''|*[!0-9]*)
      echo "transcript-attach: locate count must be a positive integer" >&2
      return 1
      ;;
  esac
  if [ "$limit" -lt 1 ]; then
    echo "transcript-attach: locate count must be a positive integer" >&2
    return 1
  fi

  if [ -z "$projects_dir" ]; then
    if [ -z "${HOME:-}" ]; then
      echo "transcript-attach: HOME is not set and CLAUDE_PROJECTS_DIR was not provided" >&2
      return 1
    fi
    projects_dir="$HOME/.claude/projects"
  fi

  if [ ! -d "$projects_dir" ]; then
    echo "transcript-attach: No Claude Code projects directory found at $projects_dir" >&2
    return 1
  fi

  cwd="$(pwd 2>/dev/null)"
  if [ -z "$cwd" ]; then
    echo "transcript-attach: Could not determine current working directory" >&2
    return 1
  fi

  tmp="$(mktemp "${TMPDIR:-/tmp}/transcript-attach-locate.XXXXXX")" || {
    echo "transcript-attach: Could not create temporary file" >&2
    return 1
  }
  add_cleanup_path "$tmp"

  while IFS= read -r project_path; do
    [ -n "$project_path" ] || continue
    key="$(munge_project_path "$project_path")"
    dir="$projects_dir/$key"
    [ -d "$dir" ] || continue

    while IFS= read -r file; do
      [ -n "$file" ] || continue
      epoch="$(file_mtime_epoch "$file")"
      size="$(file_size_bytes "$file")"
      case "$epoch" in ''|*[!0-9]*) epoch=0 ;; esac
      case "$size" in ''|*[!0-9]*) size=0 ;; esac
      printf '%s\t%s\t%s\n' "$epoch" "$size" "$file" >> "$tmp"
    done <<EOF
$(find "$dir" -maxdepth 1 -type f -name '*.jsonl' -print 2>/dev/null)
EOF
  done <<EOF
$(candidate_project_paths "$cwd")
EOF

  count="$(wc -l < "$tmp" 2>/dev/null | tr -d ' ')"
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  if [ "$count" -eq 0 ]; then
    echo "transcript-attach: No Claude Code transcripts found for $cwd under $projects_dir" >&2
    return 1
  fi

  sort -rn -k1,1 "$tmp" | head -n "$limit" | while IFS="$(printf '\t')" read -r epoch size file; do
    local modified=""
    local size_kb=0
    local escaped_path=""
    local current="false"

    idx=$((idx + 1))
    [ "$idx" -eq 1 ] && current="true"
    modified="$(epoch_to_iso "$epoch")"
    size_kb=$(( (size + 1023) / 1024 ))
    escaped_path="$(printf '%s' "$file" | json_escape)"
    printf '{"path":"%s","size_kb":%s,"modified":"%s","current":%s}\n' \
      "$escaped_path" "$size_kb" "$modified" "$current"
  done
}

scrub_one() {
  local env_file="$1"
  local in_file="$2"
  local out_file="$3"

  awk -v envfile="$env_file" -v outfile="$out_file" '
    function repeat_class(cls, n,    out, i) {
      out = ""
      for (i = 0; i < n; i++) out = out cls
      return out
    }

    function trim(s) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
      return s
    }

    function normalize_env_value(raw,    val, hash_pos) {
      val = trim(raw)
      if ((length(val) >= 2) &&
          ((substr(val, 1, 1) == "\"" && substr(val, length(val), 1) == "\"") ||
           (substr(val, 1, 1) == "\047" && substr(val, length(val), 1) == "\047"))) {
        val = substr(val, 2, length(val) - 2)
      } else {
        hash_pos = match(val, /[[:space:]]#/)
        if (hash_pos > 0) {
          val = substr(val, 1, hash_pos - 1)
        }
        val = trim(val)
      }
      return val
    }

    function replace_fixed_all(s, old, repl,    pos, rest, out) {
      if (old == "") return s
      rest = s
      out = ""
      while ((pos = index(rest, old)) > 0) {
        out = out substr(rest, 1, pos - 1) repl
        rest = substr(rest, pos + length(old))
        env_count++
      }
      return out rest
    }

    function replace_regex_all(s, pattern, repl) {
      while (match(s, pattern)) {
        s = substr(s, 1, RSTART - 1) repl substr(s, RSTART + RLENGTH)
        token_count++
      }
      return s
    }

    BEGIN {
      env_count = 0
      token_count = 0
      env_n = 0
      token_n = 0

      if (envfile != "") {
        while ((getline line < envfile) > 0) {
          sub(/\r$/, "", line)
          if (line ~ /^[[:space:]]*#/ || index(line, "=") == 0) continue

          eq = index(line, "=")
          key = substr(line, 1, eq - 1)
          val = normalize_env_value(substr(line, eq + 1))
          sub(/^[[:space:]]*export[[:space:]]+/, "", key)
          key = trim(key)

          if (key !~ /^[A-Za-z_][A-Za-z0-9_]*$/) continue
          if (length(val) < 6) continue

          env_n++
          env_key[env_n] = key
          env_value[env_n] = val
        }
        close(envfile)
      }

      ant = "[A-Za-z0-9_-]"
      alnum = "[A-Za-z0-9]"
      alnum_us = "[A-Za-z0-9_]"
      slack = "[A-Za-z0-9-]"
      aws = "[0-9A-Z]"
      bearer = "[A-Za-z0-9._~+/=-]"
      b64url = "[A-Za-z0-9_-]"

      token_pattern[++token_n] = "sk-ant-" repeat_class(ant, 8) ant "*"
      token_repl[token_n] = "[REDACTED:token]"

      token_pattern[++token_n] = "sk-proj-" repeat_class(ant, 8) ant "*"
      token_repl[token_n] = "[REDACTED:token]"

      token_pattern[++token_n] = "sk-" repeat_class(ant, 20) ant "*"
      token_repl[token_n] = "[REDACTED:token]"

      token_pattern[++token_n] = "ghp_" repeat_class(alnum, 8) alnum "*"
      token_repl[token_n] = "[REDACTED:token]"

      token_pattern[++token_n] = "gho_" repeat_class(alnum, 8) alnum "*"
      token_repl[token_n] = "[REDACTED:token]"

      token_pattern[++token_n] = "ghs_" repeat_class(alnum, 8) alnum "*"
      token_repl[token_n] = "[REDACTED:token]"

      token_pattern[++token_n] = "ghu_" repeat_class(alnum, 8) alnum "*"
      token_repl[token_n] = "[REDACTED:token]"

      token_pattern[++token_n] = "ghr_" repeat_class(alnum, 8) alnum "*"
      token_repl[token_n] = "[REDACTED:token]"

      token_pattern[++token_n] = "github_pat_" repeat_class(alnum_us, 8) alnum_us "*"
      token_repl[token_n] = "[REDACTED:token]"

      token_pattern[++token_n] = "ek_" repeat_class(alnum, 8) alnum "*"
      token_repl[token_n] = "[REDACTED:token]"

      token_pattern[++token_n] = "AIza" repeat_class(ant, 10) ant "*"
      token_repl[token_n] = "[REDACTED:token]"

      token_pattern[++token_n] = "glpat-" repeat_class(ant, 10) ant "*"
      token_repl[token_n] = "[REDACTED:token]"

      token_pattern[++token_n] = "npm_" repeat_class(alnum, 10) alnum "*"
      token_repl[token_n] = "[REDACTED:token]"

      token_pattern[++token_n] = "xox[bpars]-" repeat_class(slack, 8) slack "*"
      token_repl[token_n] = "[REDACTED:token]"

      token_pattern[++token_n] = "AKIA" repeat_class(aws, 16)
      token_repl[token_n] = "[REDACTED:token]"

      token_pattern[++token_n] = "[Bb]earer " repeat_class(bearer, 8) bearer "*"
      token_repl[token_n] = "Bearer [REDACTED:token]"

      token_pattern[++token_n] = "eyJ" repeat_class(b64url, 10) b64url "*" "[.]" repeat_class(b64url, 10) b64url "*" "[.]" repeat_class(b64url, 5) b64url "*"
      token_repl[token_n] = "[REDACTED:token]"
    }

    {
      s = $0
      for (i = 1; i <= env_n; i++) {
        s = replace_fixed_all(s, env_value[i], "[REDACTED:" env_key[i] "]")
      }
      for (i = 1; i <= token_n; i++) {
        s = replace_regex_all(s, token_pattern[i], token_repl[i])
      }
      print s > outfile
    }

    END {
      close(outfile)
      printf "%d %d\n", env_count, token_count
    }
  ' "$in_file"
}

cmd_scrub() {
  local out_dir="${1:-}"
  local env_file=""
  local in_file=""
  local out_file=""
  local base=""
  local counts=""
  local status=0
  local env_count=0
  local token_count=0
  local total_env=0
  local total_token=0
  local files=0
  local escaped_out_dir=""
  local batch_dir=""
  local seen_basenames=$'\n'
  local dest_file=""

  if [ -z "$out_dir" ] || [ "$#" -lt 2 ]; then
    echo "transcript-attach: scrub requires <out_dir> and at least one transcript file" >&2
    return 1
  fi
  shift

  for in_file in "$@"; do
    if [ ! -f "$in_file" ]; then
      echo "transcript-attach: transcript file not found: $in_file" >&2
      return 1
    fi
    base="$(basename "$in_file")"
    if [ "$out_dir/$base" = "$in_file" ]; then
      echo "transcript-attach: refusing to scrub in place: $in_file" >&2
      return 1
    fi
    case "$seen_basenames" in
      *$'\n'"$base"$'\n'*)
        echo "transcript-attach: duplicate transcript basename in input list: $base" >&2
        return 1
        ;;
    esac
    seen_basenames="${seen_basenames}${base}"$'\n'
  done

  batch_dir="$(mktemp -d "${TMPDIR:-/tmp}/transcript-attach-scrub.XXXXXX")" || {
    echo "transcript-attach: could not create temporary scrub directory" >&2
    return 1
  }
  add_cleanup_path "$batch_dir"

  [ -f "$REPO_ROOT/.env" ] && env_file="$REPO_ROOT/.env"

  for in_file in "$@"; do
    base="$(basename "$in_file")"
    out_file="$batch_dir/$base"

    counts="$(scrub_one "$env_file" "$in_file" "$out_file")"
    status=$?
    if [ "$status" -ne 0 ]; then
      rm -f "$out_file" 2>/dev/null || true
      echo "transcript-attach: failed to scrub transcript: $in_file" >&2
      return 1
    fi

    env_count="$(printf '%s' "$counts" | awk '{print $1 + 0}')"
    token_count="$(printf '%s' "$counts" | awk '{print $2 + 0}')"
    total_env=$((total_env + env_count))
    total_token=$((total_token + token_count))
    files=$((files + 1))
  done

  mkdir -p "$out_dir" 2>/dev/null || {
    echo "transcript-attach: could not create output directory: $out_dir" >&2
    return 1
  }

  for in_file in "$@"; do
    base="$(basename "$in_file")"
    dest_file="$out_dir/$base"
    if ! mv "$batch_dir/$base" "$dest_file" 2>/dev/null; then
      echo "transcript-attach: failed to publish scrubbed transcript: $base" >&2
      return 1
    fi
    add_publish_cleanup_path "$dest_file"
  done
  rm -rf "$batch_dir" 2>/dev/null || true
  PUBLISH_CLEANUP_PATHS=""

  escaped_out_dir="$(printf '%s' "$out_dir" | json_escape)"
  printf '{"files":%s,"redactions":{"env_value":%s,"token":%s},"out_dir":"%s"}\n' \
    "$files" "$total_env" "$total_token" "$escaped_out_dir"
}

case "${1:-}" in
  locate)
    shift
    cmd_locate "$@"
    ;;
  scrub)
    shift
    cmd_scrub "$@"
    ;;
  *)
    usage
    exit 1
    ;;
esac
