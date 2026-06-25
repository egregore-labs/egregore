# shellcheck shell=bash
# git-safe.sh — shared safe-git-staging helpers.
#
# Sourced by the unattended auto-commit paths (session-start git-sync,
# /handoff auto-save) so that a non-technical user — who never touches git
# directly — can't accidentally commit sibling repos sitting inside their
# checkout. This is the abstraction Egregore promises: git stays invisible
# AND safe.

# Define-once guard (safe whether sourced or, harmlessly, executed).
if [ -n "${_GIT_SAFE_SH_LOADED:-}" ]; then
  return 0 2>/dev/null || true
fi
_GIT_SAFE_SH_LOADED=1

# git_add_guarded — stage all changes like `git add -A`, but never stage
# submodule gitlinks (mode 160000) that aren't declared in .gitmodules.
#
# Sibling repos sitting inside a user's checkout would otherwise be silently
# committed as broken submodule pointers (the cause of stray `babes`,
# `tanktop-men`, `egregore-new`, … entries appearing on working branches).
# Stray links are unstaged and left untracked — never committed. Submodules
# legitimately declared in .gitmodules pass through untouched.
#
# Operates on the current working directory's repo. Always returns 0 so it is
# safe in unattended `|| true`-style pipelines.
git_add_guarded() {
  git add -A 2>/dev/null || true

  # Paths staged as gitlinks (submodule pointers).
  local _staged_links
  _staged_links=$(git ls-files --stage 2>/dev/null | awk '$1 == "160000" {print $4}')
  [ -z "$_staged_links" ] && return 0

  # Submodules legitimately declared in .gitmodules are allowed through.
  local _declared=""
  if [ -f .gitmodules ]; then
    _declared=$(git config -f .gitmodules --get-regexp '\.path$' 2>/dev/null | awk '{print $2}')
  fi

  local _stray="" _link
  while IFS= read -r _link; do
    [ -z "$_link" ] && continue
    if ! printf '%s\n' "$_declared" | grep -qxF -- "$_link" 2>/dev/null; then
      # -f because a freshly-added gitlink's staged content differs from HEAD,
      # which plain `git rm --cached` refuses. Works with or without a HEAD.
      git rm --cached -f -q -- "$_link" 2>/dev/null || true
      _stray="${_stray:+$_stray }$_link"
    fi
  done <<EOF
$_staged_links
EOF

  if [ -n "$_stray" ]; then
    echo "⚠ skipped stray submodule pointer(s) not in .gitmodules: $_stray" >&2
    echo "  (sibling repos inside the checkout — left uncommitted on purpose)" >&2
  fi
  return 0
}
