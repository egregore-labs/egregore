#!/bin/bash
#
# bin/init-gh.sh — One-shot Egregore installer that uses the `gh` CLI instead
# of the GitHub App or a manual PAT.
#
# Mirrors the UX of `npx create-egregore --open`:
#   - pick owner (personal or org)
#   - new project vs. existing project
#   - auto-adopt the current repo if you run from inside one
#   - multi-select existing repos to manage
#   - optional new project repo
#   - clones everything as siblings, wires up memory, writes configs
#   - optional teammate invite at the end
#
# Why this exists: `npx create-egregore` installs a GitHub App, which many
# enterprise orgs block by policy. `gh` is GitHub's own first-party CLI and is
# typically on the allowlist. This path needs no third-party App and no broad
# PAT — the token comes from `gh auth login` (first-party device flow).
#
# Run from anywhere:
#   curl -sLO https://raw.githubusercontent.com/egregore-labs/egregore/main/bin/init-gh.sh
#   less init-gh.sh    # optional — inspect before running
#   bash init-gh.sh
#
# Or from a cloned checkout:
#   bash bin/init-gh.sh

set -euo pipefail

# ── Rollback tracking ──────────────────────────────────────────────
# Repos we've created on GitHub during this run. On abnormal exit,
# we surface a cleanup command per repo so the user can retry cleanly
# instead of hitting the "already exists" guard on re-run.

CREATED_REPOS=()
INSTALL_COMPLETE=0

on_exit() {
  local ec=$?
  [ "$INSTALL_COMPLETE" = "1" ] && return 0
  [ "${#CREATED_REPOS[@]}" -eq 0 ] && return 0
  echo
  echo "$(printf '\033[31m%s\033[0m' '✗') Install did not complete (exit $ec)." >&2
  echo "$(printf '\033[36m%s\033[0m' '◆') Created on GitHub this run:"
  for r in "${CREATED_REPOS[@]}"; do echo "    - $r"; done
  echo "$(printf '\033[36m%s\033[0m' '◆') To delete them and retry cleanly:"
  for r in "${CREATED_REPOS[@]}"; do echo "    gh repo delete $r --yes"; done
  echo "$(printf '\033[36m%s\033[0m' '◆') Then re-run this script."
}
trap on_exit EXIT

# ── Output helpers ─────────────────────────────────────────────────

color()   { printf '\033[%sm%s\033[0m' "$1" "$2"; }
err()     { echo "$(color 31 '✗') $*" >&2; }
ok()      { echo "$(color 32 '✓') $*"; }
warn()    { echo "$(color 33 '⚠') $*"; }
info()    { echo "$(color 36 '◆') $*"; }
dim()     { color 2 "$1"; }
bold()    { color 1 "$1"; }
step()    { echo; echo "── $(bold "$1") ──"; }

prompt() {
  local question="$1" default="${2:-}" answer
  if [ -n "$default" ]; then
    read -r -p "$(printf '%s [%s]: ' "$question" "$(dim "$default")")" answer
    printf '%s' "${answer:-$default}"
  else
    read -r -p "$(printf '%s: ' "$question")" answer
    printf '%s' "$answer"
  fi
}

confirm() {
  local question="$1" default="${2:-n}" answer hint
  hint="[y/N]"; [ "$default" = "y" ] && hint="[Y/n]"
  read -r -p "$(printf '%s %s: ' "$question" "$hint")" answer
  answer="${answer:-$default}"
  [[ "$answer" == "y" || "$answer" == "Y" ]]
}

# Slugify: lowercase, replace non [a-z0-9-] with -, collapse, trim
slugify() {
  echo "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9-]/-/g; s/--*/-/g; s/^-//; s/-$//'
}

# ── Pre-flight ─────────────────────────────────────────────────────

banner() {
  cat <<'EOF'

  ███████╗ ██████╗ ██████╗ ███████╗ ██████╗  ██████╗ ██████╗ ███████╗
  ██╔════╝██╔════╝ ██╔══██╗██╔════╝██╔════╝ ██╔═══██╗██╔══██╗██╔════╝
  █████╗  ██║  ███╗██████╔╝█████╗  ██║  ███╗██║   ██║██████╔╝█████╗
  ██╔══╝  ██║   ██║██╔══██╗██╔══╝  ██║   ██║██║   ██║██╔══██╗██╔══╝
  ███████╗╚██████╔╝██║  ██║███████╗╚██████╔╝╚██████╔╝██║  ██║███████╗
  ╚══════╝ ╚═════╝ ╚═╝  ╚═╝╚══════╝ ╚═════╝  ╚═════╝ ╚═╝  ╚═╝╚══════╝

  Install via gh CLI — no GitHub App, no manual PAT.

EOF
}

banner

step "Pre-flight"

for tool in git gh jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    err "Missing required tool: $tool"
    case "$tool" in
      gh) info "Install gh: https://cli.github.com/" ;;
      jq) info "macOS: brew install jq  ·  Debian: sudo apt-get install -y jq" ;;
      git) info "Install git: https://git-scm.com/downloads" ;;
    esac
    exit 1
  fi
done
ok "git, gh, jq present"

# gh auth — gh auth status exits non-zero when not logged in
if ! gh auth status >/dev/null 2>&1; then
  warn "gh is not authenticated."
  info "Running: gh auth login"
  echo
  if ! gh auth login; then
    err "gh auth login did not complete. Re-run this script afterwards."
    exit 1
  fi
fi

# Check required scopes upfront so we fail fast with a clear fix, not deep in
# the flow with an opaque 403. `repo` is always needed. `admin:org` is only
# needed when creating under an organization — we'll re-check after owner pick.
AUTH_STATUS="$(gh auth status 2>&1 || true)"
# Extract the scopes line (format: "  - Token scopes: 'scope1', 'scope2', ...")
SCOPES_LINE="$(echo "$AUTH_STATUS" | grep -i "Token scopes" | head -1 || true)"
has_scope() { echo "$SCOPES_LINE" | grep -q "'$1'"; }

if [ -z "$SCOPES_LINE" ]; then
  warn "Could not read gh auth scopes — continuing, but repo creation may fail."
elif ! has_scope "repo"; then
  err "gh token is missing the 'repo' scope (needed to create private repos)."
  info "Run: $(bold "gh auth refresh -h github.com -s repo") and re-run this script."
  exit 1
fi
ok "gh authenticated"

# ── Detect in-repo context (parent-redirect like npx) ──────────────

IN_REPO=0
PREFILLED_REPO=""
PREFILLED_OWNER=""
PREFILLED_LOCAL=""
PREFILLED_TOPLEVEL=""

if git rev-parse --show-toplevel >/dev/null 2>&1; then
  IN_REPO=1
  PREFILLED_TOPLEVEL="$(git rev-parse --show-toplevel)"
  # Resolve submodule → superproject, worktree → main work-tree
  SUP="$(git rev-parse --show-superproject-working-tree 2>/dev/null || true)"
  [ -n "$SUP" ] && PREFILLED_TOPLEVEL="$SUP"
  COMMON="$(git -C "$PREFILLED_TOPLEVEL" rev-parse --git-common-dir 2>/dev/null || true)"
  if [ -n "$COMMON" ]; then
    [[ "$COMMON" != /* ]] && COMMON="$(cd "$PREFILLED_TOPLEVEL" && cd "$COMMON" && pwd)"
    if [ "$(basename "$COMMON")" = ".git" ]; then
      MAIN="$(dirname "$COMMON")"
      [ -d "$MAIN" ] && PREFILLED_TOPLEVEL="$MAIN"
    fi
  fi
  PREFILLED_LOCAL="$(basename "$PREFILLED_TOPLEVEL")"
  ORIGIN_URL="$(git -C "$PREFILLED_TOPLEVEL" remote get-url origin 2>/dev/null || true)"
  if [ -n "$ORIGIN_URL" ]; then
    if [[ "$ORIGIN_URL" =~ github\.com[:/]([^/]+)/([^/.]+)(\.git)?$ ]]; then
      PREFILLED_OWNER="${BASH_REMATCH[1]}"
      PREFILLED_REPO="${BASH_REMATCH[2]}"
    fi
  fi
fi

# Decide target (base) dir
BASE_DIR="$(pwd)"
if [ "$IN_REPO" = "1" ]; then
  PARENT_DIR="$(dirname "$PREFILLED_TOPLEVEL")"
  echo
  warn "You're inside a git repo: $(bold "./$PREFILLED_LOCAL")"
  echo
  info "Egregore installs as a $(bold sibling shell) that manages your repos,"
  info "not inside them. Your repo stays where it is."
  echo
  info "Options:"
  info "  1) Install in $PARENT_DIR (recommended — adopts $PREFILLED_LOCAL as managed)"
  info "  2) Pick a different directory"
  info "  3) Cancel"
  CHOICE="$(prompt "Choose" "1")"
  case "$CHOICE" in
    1) BASE_DIR="$PARENT_DIR" ;;
    2)
      PICKED="$(prompt "Install directory (absolute path)")"
      [ -z "$PICKED" ] && { err "No directory provided"; exit 1; }
      mkdir -p "$PICKED"
      BASE_DIR="$(cd "$PICKED" && pwd)"
      ;;
    *) info "Cancelled."; exit 0 ;;
  esac
fi
ok "Installing in: $BASE_DIR"

# ── Identify user + owners ─────────────────────────────────────────

step "Who are you?"

USER_LOGIN="$(gh api user --jq '.login')"
USER_NAME="$(gh api user --jq '.name // .login')"
USER_EMAIL="$(gh api user --jq '.email // ""' 2>/dev/null || true)"
ok "Signed in as $(bold "$USER_LOGIN")"

# List orgs user belongs to
ORG_LIST="$(gh api 'user/orgs?per_page=100' --jq '.[].login' 2>/dev/null || true)"

# Build owner choice list: personal first, then orgs
echo
info "Where should Egregore live?"
OWNER_CHOICES=("$USER_LOGIN (personal account)")
OWNER_VALUES=("$USER_LOGIN")
OWNER_IS_ORG=("0")
if [ -n "$ORG_LIST" ]; then
  while IFS= read -r org; do
    [ -z "$org" ] && continue
    OWNER_CHOICES+=("$org (organization)")
    OWNER_VALUES+=("$org")
    OWNER_IS_ORG+=("1")
  done <<< "$ORG_LIST"
fi

for i in "${!OWNER_CHOICES[@]}"; do
  printf "  %d) %s\n" "$((i + 1))" "${OWNER_CHOICES[$i]}"
done
OWNER_PICK="$(prompt "Choose" "1")"
if ! [[ "$OWNER_PICK" =~ ^[0-9]+$ ]] || [ "$OWNER_PICK" -lt 1 ] || [ "$OWNER_PICK" -gt "${#OWNER_VALUES[@]}" ]; then
  err "Invalid choice"; exit 1
fi
GITHUB_ORG="${OWNER_VALUES[$((OWNER_PICK - 1))]}"
IS_ORG="${OWNER_IS_ORG[$((OWNER_PICK - 1))]}"
ok "Using $(bold "$GITHUB_ORG")"

# ── New vs existing project ────────────────────────────────────────

step "What are you working on?"

# If we detected a repo owned by the chosen owner, auto-adopt it.
# If the detected repo's owner differs from the chosen one, say so explicitly —
# silently skipping is confusing when the user expects auto-adopt to fire.
AUTO_ADOPT=""
if [ -n "$PREFILLED_REPO" ] && [ -n "$PREFILLED_OWNER" ]; then
  if [ "$(echo "$PREFILLED_OWNER" | tr '[:upper:]' '[:lower:]')" = "$(echo "$GITHUB_ORG" | tr '[:upper:]' '[:lower:]')" ]; then
    AUTO_ADOPT="$PREFILLED_REPO"
  else
    info "Detected $PREFILLED_OWNER/$PREFILLED_REPO in this dir, but you picked $GITHUB_ORG as the owner."
    info "Skipping auto-adopt — Egregore only manages repos under the chosen owner."
  fi
fi

IS_NEW_PROJECT=0
if [ -n "$AUTO_ADOPT" ]; then
  info "Existing project — $(color 36 "$AUTO_ADOPT") will be managed automatically."
else
  echo "  1) Starting something new (create a fresh project repo)"
  echo "  2) Existing project (connect repos you already have)"
  PROJECT_PICK="$(prompt "Choose" "2")"
  [ "$PROJECT_PICK" = "1" ] && IS_NEW_PROJECT=1
fi

# ── Collect project info ───────────────────────────────────────────

DEFAULT_ORG_NAME="$GITHUB_ORG"
ORG_NAME="$(prompt "Name for this Egregore (team or group name)" "$DEFAULT_ORG_NAME")"
DESCRIPTION=""
if [ "$IS_NEW_PROJECT" = "1" ]; then
  DESCRIPTION="$(prompt "What are you building? (one line)")"
fi

# ── Pick existing managed repos ────────────────────────────────────

SELECTED_REPOS_JSON="[]"

if [ "$IS_NEW_PROJECT" = "0" ]; then
  step "Existing repos to manage"
  info "Fetching repos from $GITHUB_ORG..."
  REPO_LIST_RAW=""
  REPO_JQ='.[] | select(.archived | not) | select(.name | test("-memory$") | not) | select(.name != "egregore" and .name != "egregore-core") | {name: .name, description: (.description // ""), default_branch: (.default_branch // "main")}'
  if [ "$IS_ORG" = "1" ]; then
    REPO_LIST_RAW="$(gh api "orgs/$GITHUB_ORG/repos?per_page=100&sort=updated&type=all" --paginate --jq "$REPO_JQ" 2>/dev/null || true)"
  else
    REPO_LIST_RAW="$(gh api "users/$GITHUB_ORG/repos?per_page=100&sort=updated&type=owner" --paginate --jq "$REPO_JQ" 2>/dev/null || true)"
  fi
  # Slurp streamed objects into a single array; fall back to [] on any jq error
  if [ -n "$REPO_LIST_RAW" ]; then
    REPO_LIST="$(echo "$REPO_LIST_RAW" | jq -s '.' 2>/dev/null || echo '[]')"
  else
    REPO_LIST='[]'
  fi

  # Filter out auto-adopted from the picker list (we'll add it back)
  if [ -n "$AUTO_ADOPT" ]; then
    REPO_LIST="$(echo "$REPO_LIST" | jq --arg a "$AUTO_ADOPT" 'map(select(.name != $a))')"
  fi

  COUNT="$(echo "$REPO_LIST" | jq 'length' | head -1 | tr -d '[:space:]')"
  [ -z "$COUNT" ] && COUNT=0
  if [ "$COUNT" -gt 0 ] 2>/dev/null; then
    echo
    info "Which other repos should Egregore manage? (enter comma-separated numbers, or Enter for none)"
    # Portable: read into arrays without mapfile (bash 3.2 compat)
    REPO_NAMES=(); REPO_BRANCHES=(); REPO_DESCS=()
    while IFS= read -r line; do REPO_NAMES+=("$line"); done < <(echo "$REPO_LIST" | jq -r '.[].name')
    while IFS= read -r line; do REPO_BRANCHES+=("$line"); done < <(echo "$REPO_LIST" | jq -r '.[].default_branch')
    while IFS= read -r line; do REPO_DESCS+=("$line"); done < <(echo "$REPO_LIST" | jq -r '.[].description')
    for i in "${!REPO_NAMES[@]}"; do
      d="${REPO_DESCS[$i]}"
      [ -n "$d" ] && d=" — $(dim "$d")"
      printf "  %2d) %s%s\n" "$((i + 1))" "${REPO_NAMES[$i]}" "$d"
    done
    PICKS="$(prompt "Numbers")"
    if [ -n "$PICKS" ]; then
      IFS=',' read -ra PICK_ARR <<< "$PICKS"
      for raw in "${PICK_ARR[@]}"; do
        n="$(echo "$raw" | xargs)"
        [[ ! "$n" =~ ^[0-9]+$ ]] && continue
        [ "$n" -lt 1 ] || [ "$n" -gt "${#REPO_NAMES[@]}" ] && continue
        idx=$((n - 1))
        SELECTED_REPOS_JSON="$(echo "$SELECTED_REPOS_JSON" \
          | jq --arg name "${REPO_NAMES[$idx]}" --arg branch "${REPO_BRANCHES[$idx]}" \
            '. += [{name: $name, base_branch: $branch}]')"
      done
    fi
  else
    info "No existing repos found under $GITHUB_ORG (or all are archived/memory repos)."
    info "Continuing — you can add managed repos later by editing egregore.json."
  fi
fi

# Re-add the auto-adopted repo at the front
if [ -n "$AUTO_ADOPT" ]; then
  ADOPT_BRANCH="$(gh api "repos/$GITHUB_ORG/$AUTO_ADOPT" --jq '.default_branch // "main"' 2>/dev/null || echo "main")"
  SELECTED_REPOS_JSON="$(echo "$SELECTED_REPOS_JSON" \
    | jq --arg name "$AUTO_ADOPT" --arg branch "$ADOPT_BRANCH" \
      '[{name: $name, base_branch: $branch}] + .')"
fi

# ── Optional new project repo ──────────────────────────────────────

NEW_PROJECT_REPO=""
if [ "$IS_NEW_PROJECT" = "1" ]; then
  step "Project repo"
  info "Your Egregore has its own repo for memory + config."
  info "If you also want a separate repo for your code project, name it now."
  RAW_NEW="$(prompt "Project repo name (Enter to skip)")"
  if [ -n "$RAW_NEW" ]; then
    NEW_PROJECT_REPO="$(slugify "$RAW_NEW")"
  fi
fi

# ── Derive names ───────────────────────────────────────────────────

NAME_SLUG="$(slugify "$ORG_NAME")"
[ -z "$NAME_SLUG" ] && NAME_SLUG="egregore"
GH_PREFIX="$(slugify "$GITHUB_ORG")"
if [ "$GH_PREFIX" = "$NAME_SLUG" ]; then
  SLUG="$NAME_SLUG"
else
  SLUG="${GH_PREFIX}-${NAME_SLUG}"
fi
REPO_NAME="$NAME_SLUG"
MEMORY_REPO_NAME="${NAME_SLUG}-memory"

# If new-project repo collides with core/memory names, force a different slug
if [ -n "$NEW_PROJECT_REPO" ]; then
  while [ "$NEW_PROJECT_REPO" = "$REPO_NAME" ] || [ "$NEW_PROJECT_REPO" = "$MEMORY_REPO_NAME" ]; do
    warn "$NEW_PROJECT_REPO conflicts with the Egregore/memory repo names."
    RAW_NEW="$(prompt "Pick a different name (Enter to skip)")"
    [ -z "$RAW_NEW" ] && { NEW_PROJECT_REPO=""; break; }
    NEW_PROJECT_REPO="$(slugify "$RAW_NEW")"
  done
fi

# ── Guard: existing egregore instance ──────────────────────────────

step "Checking GitHub state"

EGRE_EXISTS=0
if gh api "repos/$GITHUB_ORG/$REPO_NAME" >/dev/null 2>&1; then
  EGRE_EXISTS=1
  # Does it already have egregore.json?
  if gh api "repos/$GITHUB_ORG/$REPO_NAME/contents/egregore.json" >/dev/null 2>&1; then
    warn "$GITHUB_ORG/$REPO_NAME already has Egregore set up."
    echo
    info "To join it, a teammate would run:"
    info "  $(bold "gh repo clone $GITHUB_ORG/$REPO_NAME && cd $REPO_NAME && claude")"
    echo
    info "To set up a different one, re-run and choose a different team name."
    exit 0
  fi
fi
ok "Names available"

# ── Create core egregore repo (from template) ──────────────────────

step "Creating Egregore repo"

CORE_FULL="$GITHUB_ORG/$REPO_NAME"
if [ "$EGRE_EXISTS" = "1" ]; then
  info "$CORE_FULL exists (empty, no config) — using it"
else
  CREATE_DESC="${DESCRIPTION:-Egregore instance}"
  if gh repo create "$CORE_FULL" --template egregore-labs/egregore --private --description "$CREATE_DESC" >/dev/null; then
    ok "Created $CORE_FULL (from template)"
    CREATED_REPOS+=("$CORE_FULL")
  else
    warn "Template generation failed — falling back to empty repo"
    if gh repo create "$CORE_FULL" --private --description "$CREATE_DESC" --add-readme >/dev/null; then
      ok "Created $CORE_FULL"
      CREATED_REPOS+=("$CORE_FULL")
    else
      err "Could not create $CORE_FULL"; exit 1
    fi
  fi
  # Wait until the repo is materialized (template generation can lag a few seconds)
  tries=0
  until gh api "repos/$CORE_FULL" >/dev/null 2>&1; do
    tries=$((tries + 1))
    [ "$tries" -gt 15 ] && { err "Repo creation timed out"; exit 1; }
    sleep 2
  done
fi

# ── Create memory repo ─────────────────────────────────────────────

step "Creating memory repo"

MEM_FULL="$GITHUB_ORG/$MEMORY_REPO_NAME"
if gh api "repos/$MEM_FULL" >/dev/null 2>&1; then
  info "$MEM_FULL already exists — using it"
else
  if gh repo create "$MEM_FULL" --private --add-readme --description "$ORG_NAME shared memory" >/dev/null; then
    ok "Created $MEM_FULL"
    CREATED_REPOS+=("$MEM_FULL")
  else
    err "Could not create $MEM_FULL"; exit 1
  fi
fi

# ── Create new project repo (optional) ─────────────────────────────

if [ -n "$NEW_PROJECT_REPO" ]; then
  step "Creating project repo"
  PROJ_FULL="$GITHUB_ORG/$NEW_PROJECT_REPO"
  if gh api "repos/$PROJ_FULL" >/dev/null 2>&1; then
    info "$PROJ_FULL already exists — adding to managed repos"
  else
    if gh repo create "$PROJ_FULL" --private --add-readme --description "${DESCRIPTION:-Project repo}" >/dev/null; then
      ok "Created $PROJ_FULL"
      CREATED_REPOS+=("$PROJ_FULL")
    else
      warn "Could not create $PROJ_FULL — skipping"
      NEW_PROJECT_REPO=""
    fi
  fi
  if [ -n "$NEW_PROJECT_REPO" ]; then
    SELECTED_REPOS_JSON="$(echo "$SELECTED_REPOS_JSON" \
      | jq --arg name "$NEW_PROJECT_REPO" --arg branch "main" \
        '. += [{name: $name, base_branch: $branch}]')"
  fi
fi

# ── Clone everything as siblings ───────────────────────────────────

step "Cloning locally"

EGREGORE_DIR="$BASE_DIR/$REPO_NAME"
MEMORY_DIR="$BASE_DIR/$MEMORY_REPO_NAME"

clone_via_gh() {
  local full="$1" dest="$2" label="$3"
  if [ -d "$dest/.git" ]; then
    warn "$(basename "$dest")/ already exists — leaving as-is"
    configure_gh_creds "$dest"
    return 0
  fi
  if gh repo clone "$full" "$dest" -- --quiet >/dev/null 2>&1; then
    ok "Cloned $label"
    configure_gh_creds "$dest"
    return 0
  fi
  warn "Could not clone $full"
  return 1
}

# Make git push/fetch use gh's active-account token for this repo specifically.
# Without this, on multi-account gh setups (or macOS keychain caching a different
# github.com account), `git push` falls back to a stale credential → 403.
# The empty helper clears any inherited global helpers for this repo only, then
# we add gh as the sole source of truth.
configure_gh_creds() {
  local dir="$1"
  [ ! -d "$dir/.git" ] && return 0
  git -C "$dir" config --local --replace-all credential.helper '' 2>/dev/null || true
  git -C "$dir" config --local --add credential.helper '!gh auth git-credential' 2>/dev/null || true
}

# Add a shell alias `<name>='cd <egregoreDir> && claude start'` to the right
# rc file so the user can launch the session from anywhere. Ports npx's
# installShellAlias (packages/create-egregore/lib/setup.js). Idempotent: if the
# user already has an alias pointing at this dir, reuse the name; remove any
# older line pointing at the dir or with the same name before appending.
SHELL_ALIAS_NAME=""
SHELL_ALIAS_PROFILE=""

install_shell_alias() {
  local dir="$1" slug="$2"
  local shell_name profile="" profile_file is_fish=0
  shell_name="$(basename "${SHELL:-bash}")"

  case "$shell_name" in
    zsh)  profile="$HOME/.zshrc" ;;
    fish) profile="$HOME/.config/fish/config.fish"; is_fish=1 ;;
    *)
      for f in .bash_profile .bashrc .profile; do
        [ -f "$HOME/$f" ] && { profile="$HOME/$f"; break; }
      done
      [ -z "$profile" ] && profile="$HOME/.${shell_name}rc"
      ;;
  esac
  profile_file="$(basename "$profile")"

  # Ensure parent dir exists (fish profile lives under ~/.config/fish/)
  mkdir -p "$(dirname "$profile")" 2>/dev/null || true
  touch "$profile" 2>/dev/null || { warn "Could not write to $profile — skipping alias"; return 0; }

  # If this dir already has an alias, reuse the name
  local existing=""
  if grep -F -- "$dir" "$profile" >/dev/null 2>&1; then
    existing="$(grep -F -- "$dir" "$profile" | head -1 \
      | sed -nE "s/^alias ([A-Za-z_][A-Za-z0-9_-]*)[= ].*/\1/p" | head -1)"
  fi

  # Default alias name
  local default_name
  if [ -n "$existing" ]; then
    default_name="$existing"
  elif ! grep -qE '^alias egregore[= ]' "$profile" 2>/dev/null; then
    default_name="egregore"
  else
    default_name="$slug"
  fi

  echo
  info "This instance can be launched from any terminal with a shell alias."
  local alias_name
  alias_name="$(prompt "Command name" "$default_name")"
  [ -z "$alias_name" ] && alias_name="$default_name"

  # Remove old lines: any alias pointing to this dir, any alias with same name
  local tmp="$profile.egre-tmp.$$"
  if [ "$is_fish" = "1" ]; then
    grep -v -F -- "$dir" "$profile" 2>/dev/null | grep -vE "^alias $alias_name " > "$tmp" || true
  else
    grep -v -F -- "$dir" "$profile" 2>/dev/null | grep -vE "^alias $alias_name=" > "$tmp" || true
  fi

  local alias_cmd="cd \"$dir\" && claude start"
  if [ "$is_fish" = "1" ]; then
    printf '\nalias %s %s\n' "$alias_name" "'$alias_cmd'" >> "$tmp"
  else
    printf "\nalias %s=%s\n" "$alias_name" "'$alias_cmd'" >> "$tmp"
  fi

  mv "$tmp" "$profile"
  ok "Added alias $(bold "$alias_name") to $profile_file"
  SHELL_ALIAS_NAME="$alias_name"
  SHELL_ALIAS_PROFILE="$profile_file"
}

# Core + memory clones are load-bearing — every downstream step assumes
# these dirs exist. Hard-exit with recovery steps if either fails.
if ! clone_via_gh "$CORE_FULL" "$EGREGORE_DIR" "$REPO_NAME"; then
  err "Could not clone $CORE_FULL locally (repo exists on GitHub)."
  info "Recovery:"
  info "  1) Check: gh auth status  and  your network"
  info "  2) Manually clone: gh repo clone $CORE_FULL $EGREGORE_DIR"
  info "  3) Re-run this script — it will skip steps already done"
  exit 1
fi
if ! clone_via_gh "$MEM_FULL" "$MEMORY_DIR" "$MEMORY_REPO_NAME"; then
  err "Could not clone $MEM_FULL locally (repo exists on GitHub)."
  info "Recovery: gh repo clone $MEM_FULL $MEMORY_DIR  then re-run"
  exit 1
fi

# Set repo-local git identity inside each clone (so commits attribute correctly)
set_identity() {
  local dir="$1"
  [ ! -d "$dir/.git" ] && return 0
  git -C "$dir" config user.name "$USER_NAME" 2>/dev/null || true
  git -C "$dir" config user.email "${USER_LOGIN}@users.noreply.github.com" 2>/dev/null || true
}
set_identity "$EGREGORE_DIR"
set_identity "$MEMORY_DIR"

# Ensure the egregore repo has a `develop` branch — /save PRs target develop
# and the branching convention assumes origin/develop exists. Ported from
# packages/create-egregore/lib/setup.js:ensureDevelop. Idempotent.
#
# IMPORTANT: we call this AFTER pushing egregore.json to main, so develop
# is branched from a state that includes the config. Otherwise any /save
# branch (branched from develop) inherits a repo with no egregore.json and
# session-start fails to read org context. The call happens later in the
# script, not here — this function is just defined for use below.
ensure_develop() {
  local dir="$1"
  [ ! -d "$dir/.git" ] && return 0
  # Already on remote?
  if [ -n "$(git -C "$dir" ls-remote --heads origin develop 2>/dev/null)" ]; then
    return 0
  fi
  # Detect default branch from origin/HEAD, fallback to main/master
  local default=""
  default="$(git -C "$dir" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || true)"
  if [ -z "$default" ]; then
    for candidate in main master; do
      if git -C "$dir" show-ref --verify --quiet "refs/remotes/origin/$candidate" 2>/dev/null; then
        default="$candidate"; break
      fi
    done
  fi
  [ -z "$default" ] && return 0
  git -C "$dir" branch develop "origin/$default" >/dev/null 2>&1 || true
  git -C "$dir" push -u origin develop >/dev/null 2>&1 \
    && ok "develop branch created on $(basename "$dir")" \
    || warn "Could not push develop branch — run: git -C $dir push -u origin develop"
}
# ensure_develop called later, AFTER egregore.json is pushed to main.

# Clone managed repos (skip auto-adopted — it already lives on disk at PREFILLED_TOPLEVEL)
MANAGED_COUNT="$(echo "$SELECTED_REPOS_JSON" | jq 'length')"
if [ "$MANAGED_COUNT" -gt 0 ]; then
  for i in $(seq 0 $((MANAGED_COUNT - 1))); do
    NAME="$(echo "$SELECTED_REPOS_JSON" | jq -r ".[$i].name")"
    if [ -n "$AUTO_ADOPT" ] && [ "$NAME" = "$AUTO_ADOPT" ]; then
      ok "Using existing $NAME/ (your current repo)"
      continue
    fi
    clone_via_gh "$GITHUB_ORG/$NAME" "$BASE_DIR/$NAME" "$NAME" || true
    set_identity "$BASE_DIR/$NAME"
  done
fi

# ── Memory scaffold ────────────────────────────────────────────────

step "Memory scaffold"

SCAFFOLD_DIRS=("people" "handoffs" "knowledge/decisions" "knowledge/patterns" "knowledge/findings" "quests" "wraps" "artifacts")
NEEDS_COMMIT=0
for d in "${SCAFFOLD_DIRS[@]}"; do
  if [ ! -e "$MEMORY_DIR/$d/.gitkeep" ]; then
    mkdir -p "$MEMORY_DIR/$d"
    : > "$MEMORY_DIR/$d/.gitkeep"
    NEEDS_COMMIT=1
  fi
done

if [ "$NEEDS_COMMIT" = "1" ]; then
  git -C "$MEMORY_DIR" add -A
  git -C "$MEMORY_DIR" commit -m "Initialize memory scaffold" >/dev/null 2>&1 || true
  if git -C "$MEMORY_DIR" push -u origin HEAD >/dev/null 2>&1; then
    ok "Pushed scaffold"
  else
    warn "Could not push scaffold — run: git -C $MEMORY_DIR push"
  fi
else
  ok "Scaffold already in place"
fi

# ── Symlink memory/ ────────────────────────────────────────────────

step "Linking memory"

MEMORY_LINK="$EGREGORE_DIR/memory"
if [ -L "$MEMORY_LINK" ]; then
  warn "memory/ already a symlink — leaving alone"
elif [ -e "$MEMORY_LINK" ]; then
  err "$MEMORY_LINK exists but is not a symlink. Remove/rename and re-run."
  exit 1
else
  ln -s "$MEMORY_DIR" "$MEMORY_LINK"
  ok "memory/ → $MEMORY_DIR"
fi

# ── Write configs (local + push egregore.json to remote) ───────────

step "Writing configs"

MEMORY_HTTPS="https://github.com/$GITHUB_ORG/$MEMORY_REPO_NAME.git"

NEW_CONFIG="$(jq -n \
  --arg org_name "$ORG_NAME" \
  --arg github_org "$GITHUB_ORG" \
  --arg memory_repo "$MEMORY_HTTPS" \
  --arg repo_name "$REPO_NAME" \
  --arg slug "$SLUG" \
  --argjson repos "$SELECTED_REPOS_JSON" \
  '{
    mode: "local",
    org_name: $org_name,
    github_org: $github_org,
    memory_repo: $memory_repo,
    repo_name: $repo_name,
    slug: $slug,
    repos: $repos,
    upstream_url: "https://github.com/egregore-labs/egregore.git"
  }')"

# On re-run, merge with existing egregore.json so user customizations
# (telegram_group_link, report_url, manually-added fields) survive.
# Recursive merge with `*`: second (new) wins on conflict, existing keeps
# keys this script doesn't know about. `repos` is fully replaced — that's
# the user's intent (their selections in this run are authoritative).
EGRE_JSON="$EGREGORE_DIR/egregore.json"
if [ -f "$EGRE_JSON" ]; then
  MERGED="$(jq -s '.[0] * .[1]' "$EGRE_JSON" <(echo "$NEW_CONFIG") 2>/dev/null || echo "$NEW_CONFIG")"
  echo "$MERGED" > "$EGRE_JSON"
  ok "egregore.json (merged with existing)"
else
  echo "$NEW_CONFIG" > "$EGRE_JSON"
  ok "egregore.json (local)"
fi

# Push egregore.json to the remote core repo so joiners can read it before cloning
git -C "$EGREGORE_DIR" add egregore.json >/dev/null 2>&1 || true
if ! git -C "$EGREGORE_DIR" diff --cached --quiet 2>/dev/null; then
  git -C "$EGREGORE_DIR" commit -m "Configure egregore for $ORG_NAME" >/dev/null 2>&1 || true
  git -C "$EGREGORE_DIR" push >/dev/null 2>&1 && ok "Pushed egregore.json to remote" || warn "Push failed — run git push in $EGREGORE_DIR"
fi

# NOW create develop — from main WITH egregore.json. Branching develop earlier
# would leave it at the template commit, and every /save branch (which starts
# from develop) would have no egregore.json → session-start can't read org.
ensure_develop "$EGREGORE_DIR"

# Write .env (GITHUB_TOKEN from gh so skills can call the API without asking user again)
GH_TOKEN="$(gh auth token 2>/dev/null || true)"
if [ -n "$GH_TOKEN" ]; then
  ENV_FILE="$EGREGORE_DIR/.env"
  touch "$ENV_FILE"
  # Preserve other keys; replace or append GITHUB_TOKEN
  if grep -q '^GITHUB_TOKEN=' "$ENV_FILE" 2>/dev/null; then
    tmp="$ENV_FILE.tmp.$$"
    grep -v '^GITHUB_TOKEN=' "$ENV_FILE" > "$tmp" || true
    echo "GITHUB_TOKEN=$GH_TOKEN" >> "$tmp"
    mv "$tmp" "$ENV_FILE"
  else
    echo "GITHUB_TOKEN=$GH_TOKEN" >> "$ENV_FILE"
  fi
  # chmod AFTER all writes — mv replaces inode and drops 0600 on the replace path
  chmod 600 "$ENV_FILE"
  ok ".env (GITHUB_TOKEN from gh, 0600)"
else
  warn "Could not read gh token — .env not written. /save and /invite will prompt."
fi

# Write .egregore-state.json
DISPLAY_DEFAULT="${USER_NAME:-$USER_LOGIN}"
DISPLAY_NAME="$(prompt "What should we call you?" "$DISPLAY_DEFAULT")"

# On re-run, preserve onboarding_complete=true if the user has already onboarded.
# Otherwise the user would be re-onboarded every time this script runs.
EXISTING_ONBOARDED="false"
if [ -f "$EGREGORE_DIR/.egregore-state.json" ]; then
  prev="$(jq -r '.onboarding_complete // false' "$EGREGORE_DIR/.egregore-state.json" 2>/dev/null || echo false)"
  [ "$prev" = "true" ] && EXISTING_ONBOARDED="true"
fi

STATE="$(jq -n \
  --arg github_username "$USER_LOGIN" \
  --arg github_name "$USER_NAME" \
  --arg display_name "$DISPLAY_NAME" \
  --arg email "$USER_EMAIL" \
  --argjson onboarding_complete "$EXISTING_ONBOARDED" \
  '{
    github_username: $github_username,
    github_name: $github_name,
    display_name: $display_name,
    email: $email,
    onboarding_complete: $onboarding_complete,
    usage_type: "founder_group",
    org_setup: true,
    github_configured: true,
    workspace_ready: true
  }')"
echo "$STATE" > "$EGREGORE_DIR/.egregore-state.json"
if [ "$EXISTING_ONBOARDED" = "true" ]; then
  ok ".egregore-state.json (preserved onboarding_complete: true)"
else
  ok ".egregore-state.json"
fi

# ── Founder person file ────────────────────────────────────────────

TODAY="$(date -u +%Y-%m-%d)"
PERSON_FILE="$MEMORY_DIR/people/${USER_LOGIN}.md"
if [ ! -e "$PERSON_FILE" ]; then
  mkdir -p "$MEMORY_DIR/people"
  cat > "$PERSON_FILE" <<EOF
---
name: $DISPLAY_NAME
github: $USER_LOGIN
role: founder
joined: $TODAY
---
EOF
  git -C "$MEMORY_DIR" add "people/${USER_LOGIN}.md" >/dev/null 2>&1 || true
  git -C "$MEMORY_DIR" commit -m "Add founder $USER_LOGIN" >/dev/null 2>&1 || true
  git -C "$MEMORY_DIR" push >/dev/null 2>&1 || true
  ok "Created people/${USER_LOGIN}.md"
fi

# ── Shell alias so the user can launch from anywhere ──────────────

step "Shell alias"
install_shell_alias "$EGREGORE_DIR" "$SLUG"

# ── Optional teammate invite ───────────────────────────────────────

step "Invite a teammate"

INV_USER="$(prompt "Teammate's GitHub username (Enter to skip)")"
if [ -n "$INV_USER" ]; then
  invite_to_repo() {
    local repo="$1" username="$2"
    gh api --method PUT "repos/$GITHUB_ORG/$repo/collaborators/$username" -f permission=push >/dev/null 2>&1 \
      && ok "Invited $username → $repo" \
      || warn "Could not invite $username to $repo"
  }
  invite_to_repo "$REPO_NAME" "$INV_USER"
  invite_to_repo "$MEMORY_REPO_NAME" "$INV_USER"
  if [ "$MANAGED_COUNT" -gt 0 ]; then
    for i in $(seq 0 $((MANAGED_COUNT - 1))); do
      NAME="$(echo "$SELECTED_REPOS_JSON" | jq -r ".[$i].name")"
      invite_to_repo "$NAME" "$INV_USER"
    done
  fi

  INV_PERSON_FILE="$MEMORY_DIR/people/${INV_USER}.md"
  if [ ! -e "$INV_PERSON_FILE" ]; then
    cat > "$INV_PERSON_FILE" <<EOF
---
name: $INV_USER
github: $INV_USER
invited_by: $USER_LOGIN
joined: $TODAY
---
EOF
    git -C "$MEMORY_DIR" add "people/${INV_USER}.md" >/dev/null 2>&1 || true
    git -C "$MEMORY_DIR" commit -m "Invite $INV_USER" >/dev/null 2>&1 || true
    git -C "$MEMORY_DIR" push >/dev/null 2>&1 || true
  fi
  echo
  info "Tell $INV_USER to run either:"
  info "  $(bold "curl -sLO https://raw.githubusercontent.com/egregore-labs/egregore/main/bin/join-gh.sh && bash join-gh.sh $GITHUB_ORG/$REPO_NAME")"
  info "  $(bold "npx create-egregore join $GITHUB_ORG/$REPO_NAME")"
  info "Both accept the invite, clone core + memory + managed repos as siblings,"
  info "symlink memory, write .env, install a shell alias, and run /onboarding."
  info "The gh path has no third-party App and no manual PAT."
fi

# ── Done ───────────────────────────────────────────────────────────

step "Done"

INSTALL_COMPLETE=1
echo
ok "Egregore is ready for $(bold "$ORG_NAME")"
echo
info "Workspace:"
info "  $(color 36 "$EGREGORE_DIR/")"
info "  $(color 36 "$MEMORY_DIR/")"
if [ "$MANAGED_COUNT" -gt 0 ]; then
  for i in $(seq 0 $((MANAGED_COUNT - 1))); do
    NAME="$(echo "$SELECTED_REPOS_JSON" | jq -r ".[$i].name")"
    info "  $(color 36 "$BASE_DIR/$NAME/")"
  done
fi
echo
info "Next steps:"
if [ -n "$SHELL_ALIAS_NAME" ]; then
  info "  Open a $(bold "new terminal") and run: $(bold "$SHELL_ALIAS_NAME")"
  info "  (or: $(bold "cd $EGREGORE_DIR && claude start"))"
else
  info "  cd $EGREGORE_DIR"
  info "  claude start    # first session runs /onboarding automatically"
fi
echo
