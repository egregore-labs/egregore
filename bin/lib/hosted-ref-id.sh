#!/usr/bin/env bash
# hosted-ref-id.sh — Public ids for memory files published by reference.
#
# A Connected publish also hosts each memory file its source mentions in
# backticks (`memory/…`), so the mention can link to it. Org pages open for
# anyone who has the URL, so the hosted id must not be something an outsider
# can work out. The canonical id (bin/lib/artifact-id.sh) is a hash of the
# path and can be computed by anyone who knows the path, so it is never used
# as a hosted id. Each referenced file instead gets a random id (128 bits)
# the first time it is hosted. The registry record for that publish
# (memory/artifacts/, fields `canonical_id` and `url`) keeps it, so every
# later publish in the org reuses it and links stay stable.
#
# Canonical ids are unchanged: they stay the file's identity everywhere else.
#
# Requires bin/lib/artifact-id.sh to be sourced first.

# hosted_ref_id_mint <canonical-id>
# Prints a new random hosted id: the canonical id's kind letter (m or h), a
# hyphen and 32 hex characters.
hosted_ref_id_mint() {
  local canonical="$1" kind hex
  kind="${canonical%%-*}"
  case "$kind" in m|h) ;; *) return 1 ;; esac
  hex="$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
  [[ "$hex" =~ ^[0-9a-f]{32}$ ]] || hex="$(openssl rand -hex 16 2>/dev/null)"
  [[ "$hex" =~ ^[0-9a-f]{32}$ ]] || return 1
  printf '%s-%s' "$kind" "$hex"
}

# hosted_ref_id_valid <hosted-id> <canonical-id>
# True for an id hosted_ref_id_mint could have produced for this file.
hosted_ref_id_valid() {
  [[ "$1" =~ ^[mh]-[0-9a-f]{32}$ ]] && [ "${1%%-*}" = "${2%%-*}" ]
}

# hosted_ref_id_lookup <registry-dir> <org-slug> <canonical-id>
# Prints the hosted id the registry records for this file in this org, or
# nothing. Records from before random ids carry the canonical id as their
# hosted id; they fail the format check and are never reused.
hosted_ref_id_lookup() {
  local registry="$1" org="$2" canonical="$3" record url id
  [[ "$canonical" =~ ^[mh]-[0-9a-f]{12}$ ]] || return 0
  [ -d "$registry" ] || return 0
  # Newest record first (records are named by date). Every record for one
  # file carries the same id, except when two people published it for the
  # first time at once. Both ids then serve, and records also carry the
  # hosted id in their name, so every machine settles on the same one.
  record="$(grep -rlE "^canonical_id: \"?${canonical}\"?$" "$registry" 2>/dev/null | LC_ALL=C sort | tail -1)" || true
  [ -n "$record" ] || return 0
  url="$(sed -n '/^---$/,/^---$/p' "$record" 2>/dev/null | grep -m1 '^url:' | sed 's/^url:[[:space:]]*//; s/^"//; s/"$//')" || true
  if [ -n "$org" ]; then
    case "$url" in */view/"$org"/*) ;; *) return 0 ;; esac
  fi
  id="${url##*/}"
  if hosted_ref_id_valid "$id" "$canonical"; then
    printf '%s' "$id"
  fi
  return 0
}

# hosted_ref_ids_for_source <source-file> <registry-dir> <org-slug> <mint: 0|1>
# Prints one "<memory path> <hosted id>" line per distinct `memory/…` mention
# in the source: the recorded id, else (mint=1) a new one. Without mint, a
# file with no recorded id is left out.
hosted_ref_ids_for_source() {
  local source="$1" registry="$2" org="$3" mint="$4" refs ref canonical id
  refs="$(grep -Eo '`memory/[^`[:space:]]+\.(md|html)`' "$source" 2>/dev/null \
    | sed 's/^`//; s/`$//' | LC_ALL=C sort -u)" || true
  [ -n "$refs" ] || return 0
  while IFS= read -r ref; do
    canonical="$(artifact_id_from_path "$ref")" || continue
    id="$(hosted_ref_id_lookup "$registry" "$org" "$canonical")"
    if [ -z "$id" ] && [ "$mint" = "1" ]; then
      id="$(hosted_ref_id_mint "$canonical")" || continue
    fi
    if [ -n "$id" ]; then
      printf '%s %s\n' "$ref" "$id"
    fi
  done <<< "$refs"
  return 0
}

# hosted_ref_id_from_list <ids> <memory path>
# Prints the hosted id for the path from "<memory path> <hosted id>" lines.
hosted_ref_id_from_list() {
  printf '%s\n' "$1" | awk -v ref="$2" '$1 == ref { print $2; exit }'
}

# hosted_ref_rewrite_links <html-file> <view-prefix> <ids>
# The renderer links each mention to <view-prefix>/<canonical id>. Points
# those links at the hosted ids in <ids> ("<memory path> <hosted id>" lines)
# instead. <view-prefix> is the org's view URL, e.g.
# https://egregore.xyz/view/acme.
hosted_ref_rewrite_links() {
  local html="$1" prefix="$2" ids="$3" ref id canonical pattern replacement
  local -a script=()
  pattern="$(printf '%s' "$prefix" | sed 's/[][\.*^$#]/\\&/g')"
  replacement="$(printf '%s' "$prefix" | sed 's/[\&#]/\\&/g')"
  while IFS=' ' read -r ref id; do
    [ -n "$ref" ] && [ -n "$id" ] || continue
    canonical="$(artifact_id_from_path "$ref")" || continue
    hosted_ref_id_valid "$id" "$canonical" || continue
    script+=(-e "s#${pattern}/${canonical}\"#${replacement}/${id}\"#g")
  done <<< "$ids"
  [ "${#script[@]}" -gt 0 ] || return 0
  sed "${script[@]}" "$html" > "$html.links" && mv "$html.links" "$html"
}
