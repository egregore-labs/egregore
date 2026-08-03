# shellcheck shell=bash
# Shared handoff metadata extraction for legacy markdown headers and YAML front matter.

eg_handoff_md_field() {
  local file="$1"
  local key="$2"
  local val

  val="$(grep -m1 "^\*\*${key}\*\*:" "$file" 2>/dev/null | sed "s/^\*\*${key}\*\*:[[:space:]]*//" | xargs 2>/dev/null || true)"
  if [ -z "$val" ]; then
    val="$(grep -m1 "^\*\*${key}:\*\*" "$file" 2>/dev/null | sed "s/^\*\*${key}:\*\*[[:space:]]*//" | xargs 2>/dev/null || true)"
  fi

  printf '%s\n' "$val"
}

eg_handoff_yaml_field() {
  local file="$1"
  local key="$2"

  sed -n '/^---$/,/^---$/p' "$file" 2>/dev/null \
    | grep -m1 "^${key}:" 2>/dev/null \
    | sed "s/^${key}:[[:space:]]*//" \
    | sed 's/^"//; s/"$//' \
    | sed "s/^'//; s/'$//" \
    | xargs 2>/dev/null || true
}

eg_handoff_author_from_filename() {
  local file="$1"
  local name

  name="$(basename "$file" .md)"
  if [[ "$name" =~ ^[0-9]{2}-([^-]+)- ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  elif [[ "$name" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-([^-]+)- ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  fi
}

eg_handoff_date_from_filename() {
  local file="$1"
  local name dir day

  name="$(basename "$file" .md)"
  dir="$(basename "$(dirname "$file")")"
  if [[ "$dir" =~ ^[0-9]{4}-[0-9]{2}$ && "$name" =~ ^([0-9]{2})- ]]; then
    day="${BASH_REMATCH[1]}"
    printf '%s-%s\n' "$dir" "$day"
  elif [[ "$name" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})- ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  fi
}

eg_handoff_author() {
  local file="$1"
  local author

  author="$(eg_handoff_md_field "$file" "Author")"
  [ -z "$author" ] && author="$(eg_handoff_md_field "$file" "From")"
  [ -z "$author" ] && author="$(grep -m1 '^From:' "$file" 2>/dev/null | sed 's/^From:[[:space:]]*//' | xargs 2>/dev/null || true)"
  [ -z "$author" ] && author="$(eg_handoff_yaml_field "$file" "author")"
  [ -z "$author" ] && author="$(eg_handoff_yaml_field "$file" "from")"
  [ -z "$author" ] && author="$(eg_handoff_author_from_filename "$file")"

  printf '%s\n' "$author" | sed 's/[[:space:]]*→.*//' | xargs 2>/dev/null || true
}

eg_handoff_topic() {
  local file="$1"
  local topic

  topic="$(grep -m1 '^# ' "$file" 2>/dev/null | sed 's/^# //; s/^Handoff:[[:space:]]*//' | xargs 2>/dev/null || true)"
  [ -z "$topic" ] && topic="$(eg_handoff_yaml_field "$file" "topic")"
  printf '%s\n' "$topic"
}

eg_handoff_date() {
  local file="$1"
  local date

  date="$(eg_handoff_md_field "$file" "Date")"
  [ -z "$date" ] && date="$(grep -m1 '^Date:' "$file" 2>/dev/null | sed 's/^Date:[[:space:]]*//' | xargs 2>/dev/null || true)"
  [ -z "$date" ] && date="$(eg_handoff_yaml_field "$file" "date")"
  [ -z "$date" ] && date="$(eg_handoff_date_from_filename "$file")"
  printf '%s\n' "$date"
}

eg_handoff_metadata_json() {
  local file="$1"

  jq -cn \
    --arg author "$(eg_handoff_author "$file")" \
    --arg topic "$(eg_handoff_topic "$file")" \
    --arg date "$(eg_handoff_date "$file")" \
    '{author:$author, topic:$topic, date:$date}'
}
