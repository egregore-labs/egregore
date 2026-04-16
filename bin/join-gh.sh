#!/bin/bash
#
# bin/join-gh.sh — Join an existing Egregore via the `gh` CLI.
#
# Companion to bin/init-gh.sh for the invitee side. No GitHub App, no manual
# PAT — the token comes from `gh auth login` (first-party device flow).
# Mirrors packages/create-egregore/lib/local.js:localJoinFlow.
#
# Usage:
#   bash bin/join-gh.sh <owner>/<repo>
#   bash <(curl -sL https://raw.githubusercontent.com/egregore-labs/egregore/main/bin/join-gh.sh) <owner>/<repo>
#
# Example:
#   bash bin/join-gh.sh acme-org/ops-team

set -euo pipefail

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

# ── Banner ─────────────────────────────────────────────────────────

cat <<'EOF'

  Joining an Egregore via gh CLI — no GitHub App, no manual PAT.

EOF

# ── Parse args ─────────────────────────────────────────────────────

ORG_REPO="${1:-}"
if [ -z "$ORG_REPO" ]; then
  ORG_REPO="$(prompt "Which Egregore are you joining? (format: <owner>/<repo>)")"
fi
if [[ ! "$ORG_REPO" == */* ]]; then
  err "Expected <owner>/<repo>, got: $ORG_REPO"
  info "Example: bash bin/join-gh.sh acme-org/ops-team"
  exit 1
fi
OWNER="${ORG_REPO%%/*}"
REPO="${ORG_REPO#*/}"
if [ -z "$OWNER" ] || [ -z "$REPO" ]; then
  err "Could not parse owner/repo from: $ORG_REPO"
  exit 1
fi

# ── Pre-flight ─────────────────────────────────────────────────────

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

if ! gh auth status >/dev/null 2>&1; then
  warn "gh is not authenticated."
  info "Running: gh auth login"
  echo
  if ! gh auth login; then
    err "gh auth login did not complete. Re-run this script afterwards."
    exit 1
  fi
fi
ok "gh authenticated"

USER_LOGIN="$(gh api user --jq '.login')"
USER_NAME="$(gh api user --jq '.name // .login')"
USER_EMAIL="$(gh api user --jq '.email // ""' 2>/dev/null || true)"
ok "Signed in as $(bold "$USER_LOGIN")"

# ── Detect in-repo context (optional parent-redirect) ─────────────

BASE_DIR="$(pwd)"
if git rev-parse --show-toplevel >/dev/null 2>&1; then
  TOPLEVEL="$(git rev-parse --show-toplevel)"
  SUP="$(git rev-parse --show-superproject-working-tree 2>/dev/null || true)"
  [ -n "$SUP" ] && TOPLEVEL="$SUP"
  COMMON="$(git -C "$TOPLEVEL" rev-parse --git-common-dir 2>/dev/null || true)"
  if [ -n "$COMMON" ]; then
    [[ "$COMMON" != /* ]] && COMMON="$(cd "$TOPLEVEL" && cd "$COMMON" && pwd)"
    [ "$(basename "$COMMON")" = ".git" ] && TOPLEVEL="$(dirname "$COMMON")"
  fi
  LOCAL_NAME="$(basename "$TOPLEVEL")"
  PARENT_DIR="$(dirname "$TOPLEVEL")"
  echo
  warn "You're inside a git repo: $(bold "./$LOCAL_NAME")"
  info "The joined Egregore installs as a sibling — not inside your current repo."
  echo
  info "Options:"
  info "  1) Join in $PARENT_DIR (recommended)"
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
ok "Joining in: $BASE_DIR"

# ── Accept pending repository invitations ──────────────────────────

step "Accepting invitations"

INVITES_JSON="$(gh api /user/repository_invitations --jq '.' 2>/dev/null || echo '[]')"
INVITE_COUNT="$(echo "$INVITES_JSON" | jq "[.[] | select(.repository.owner.login == \"$OWNER\")] | length" 2>/dev/null || echo 0)"
[ -z "$INVITE_COUNT" ] && INVITE_COUNT=0

if [ "$INVITE_COUNT" -gt 0 ] 2>/dev/null; then
  echo "$INVITES_JSON" | jq -r ".[] | select(.repository.owner.login == \"$OWNER\") | \"\(.id) \(.repository.full_name)\"" | while read -r inv_id inv_repo; do
    if gh api --method PATCH "/user/repository_invitations/$inv_id" >/dev/null 2>&1; then
      ok "Accepted invite to $inv_repo"
    else
      warn "Could not accept invite $inv_id ($inv_repo) — continuing"
    fi
  done
else
  info "No pending invitations from $OWNER (you may already be a collaborator)."
fi

# ── Clone core repo ────────────────────────────────────────────────

step "Cloning core repo"

EGREGORE_DIR="$BASE_DIR/$REPO"
configure_gh_creds() {
  local dir="$1"
  [ ! -d "$dir/.git" ] && return 0
  git -C "$dir" config --local --replace-all credential.helper '' 2>/dev/null || true
  git -C "$dir" config --local --add credential.helper '!gh auth git-credential' 2>/dev/null || true
}

set_identity() {
  local dir="$1"
  [ ! -d "$dir/.git" ] && return 0
  git -C "$dir" config user.name "$USER_NAME" 2>/dev/null || true
  git -C "$dir" config user.email "${USER_LOGIN}@users.noreply.github.com" 2>/dev/null || true
}

if [ -d "$EGREGORE_DIR/.git" ]; then
  warn "$EGREGORE_DIR already exists — leaving as-is"
  configure_gh_creds "$EGREGORE_DIR"
else
  if gh repo clone "$OWNER/$REPO" "$EGREGORE_DIR" -- --quiet >/dev/null 2>&1; then
    ok "Cloned $OWNER/$REPO"
    configure_gh_creds "$EGREGORE_DIR"
    set_identity "$EGREGORE_DIR"
  else
    err "Could not clone $OWNER/$REPO. Are you invited, and is the repo name correct?"
    info "Check: gh repo view $OWNER/$REPO"
    exit 1
  fi
fi

# ── Read egregore.json ─────────────────────────────────────────────

CONFIG="$EGREGORE_DIR/egregore.json"
if [ ! -f "$CONFIG" ]; then
  err "$EGREGORE_DIR has no egregore.json. Ask the admin to finish setup first."
  exit 1
fi

ORG_NAME="$(jq -r '.org_name // empty' "$CONFIG")"
[ -z "$ORG_NAME" ] && ORG_NAME="$OWNER"

# If this Egregore is configured for the hosted (connected) service, joining
# via this script won't give the user an EGREGORE_API_KEY — only GITHUB_TOKEN.
# Some skills will fail. Warn up front so the user isn't confused later.
CONFIG_MODE="$(jq -r '.mode // "local"' "$CONFIG" 2>/dev/null || echo local)"
if [ "$CONFIG_MODE" = "connected" ]; then
  echo
  warn "This Egregore is configured for the hosted service (mode: connected)."
  warn "This gh-based joiner only writes GITHUB_TOKEN. Connected mode also"
  warn "needs EGREGORE_API_KEY — skills calling bin/graph.sh or bin/notify.sh"
  warn "will fail until the admin provisions one for you."
  info "To get full connected-mode access, use npx instead:"
  info "  $(bold "npx create-egregore join $OWNER/$REPO")"
  info "Or ask the admin for a setup token."
  echo
  if ! ANSWER="$(prompt "Continue anyway (local-only access to memory/managed repos)? [y/N]" "n")" \
     || [ "$ANSWER" != "y" ] && [ "$ANSWER" != "Y" ]; then
    info "Aborted."
    exit 0
  fi
fi

# Parse memory_repo URL so we honor the owner encoded in it (may differ from
# $OWNER if the founder pointed memory at a different org). Matches npx's
# localJoinFlow (local.js:773), which uses the URL directly for clone.
MEMORY_URL="$(jq -r '.memory_repo // empty' "$CONFIG")"
MEMORY_OWNER=""
MEMORY_REPO_NAME=""
if [ -n "$MEMORY_URL" ]; then
  # Match github.com[:/]<owner>/<repo>[.git]
  if [[ "$MEMORY_URL" =~ github\.com[:/]([^/]+)/([^/.]+)(\.git)?$ ]]; then
    MEMORY_OWNER="${BASH_REMATCH[1]}"
    MEMORY_REPO_NAME="${BASH_REMATCH[2]}"
  else
    # Best-effort fallback: strip .git and take basename
    MEMORY_REPO_NAME="$(basename "${MEMORY_URL%.git}")"
  fi
fi
[ -z "$MEMORY_OWNER" ] && MEMORY_OWNER="$OWNER"
[ -z "$MEMORY_REPO_NAME" ] && MEMORY_REPO_NAME="${OWNER}-memory"
MEMORY_FULL="$MEMORY_OWNER/$MEMORY_REPO_NAME"

TELEGRAM_LINK="$(jq -r '.telegram_group_link // empty' "$CONFIG")"

ok "Found $(bold "$ORG_NAME")"

# ── Clone memory repo as sibling ───────────────────────────────────

step "Cloning shared memory"

MEMORY_DIR="$BASE_DIR/$MEMORY_REPO_NAME"
if [ -d "$MEMORY_DIR/.git" ]; then
  warn "$MEMORY_DIR already exists — leaving as-is"
  configure_gh_creds "$MEMORY_DIR"
else
  if gh repo clone "$MEMORY_FULL" "$MEMORY_DIR" -- --quiet >/dev/null 2>&1; then
    ok "Cloned memory ($MEMORY_FULL)"
    configure_gh_creds "$MEMORY_DIR"
    set_identity "$MEMORY_DIR"
  else
    warn "Could not clone $MEMORY_FULL — you may not have access yet."
    info "If the admin just invited you, wait for the invite email and re-run this script."
  fi
fi

# ── Symlink memory/ ────────────────────────────────────────────────

step "Linking memory"

MEMORY_LINK="$EGREGORE_DIR/memory"
# Gate on memory clone having succeeded — avoid a dangling symlink that would
# break every skill that reads memory/.
if [ ! -d "$MEMORY_DIR/.git" ]; then
  warn "Memory repo not cloned — skipping memory/ symlink."
  info "Once you have access, clone it manually and re-run:"
  info "  gh repo clone $MEMORY_FULL $MEMORY_DIR"
  info "  bash $0 $OWNER/$REPO"
elif [ -L "$MEMORY_LINK" ]; then
  warn "memory/ already a symlink — leaving alone"
elif [ -e "$MEMORY_LINK" ]; then
  err "$MEMORY_LINK exists but is not a symlink. Remove/rename and re-run."
  exit 1
else
  ln -s "$MEMORY_DIR" "$MEMORY_LINK"
  ok "memory/ → $MEMORY_DIR"
fi

# ── Ensure develop branch exists locally ───────────────────────────

# The founder's init-gh.sh creates develop on origin; we just need a local
# tracking branch so /save has somewhere to base its PR branches on.
if git -C "$EGREGORE_DIR" show-ref --verify --quiet refs/remotes/origin/develop 2>/dev/null; then
  git -C "$EGREGORE_DIR" show-ref --verify --quiet refs/heads/develop 2>/dev/null \
    || git -C "$EGREGORE_DIR" branch --track develop origin/develop >/dev/null 2>&1 || true
fi

# ── Write .env (GITHUB_TOKEN from gh) ──────────────────────────────

step "Writing credentials"

GH_TOKEN="$(gh auth token 2>/dev/null || true)"
if [ -n "$GH_TOKEN" ]; then
  ENV_FILE="$EGREGORE_DIR/.env"
  touch "$ENV_FILE"
  if grep -q '^GITHUB_TOKEN=' "$ENV_FILE" 2>/dev/null; then
    tmp="$ENV_FILE.tmp.$$"
    grep -v '^GITHUB_TOKEN=' "$ENV_FILE" > "$tmp" || true
    echo "GITHUB_TOKEN=$GH_TOKEN" >> "$tmp"
    mv "$tmp" "$ENV_FILE"
  else
    echo "GITHUB_TOKEN=$GH_TOKEN" >> "$ENV_FILE"
  fi
  chmod 600 "$ENV_FILE"
  ok ".env (GITHUB_TOKEN from gh, 0600)"
else
  warn "Could not read gh token — .env not written."
fi

# ── Prompt display name + write state ──────────────────────────────

DISPLAY_DEFAULT="${USER_NAME:-$USER_LOGIN}"
DISPLAY_NAME="$(prompt "What should we call you?" "$DISPLAY_DEFAULT")"

# Preserve onboarding_complete if the joiner is re-running on an already-onboarded clone
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
    usage_type: "joiner_group",
    org_setup: true,
    github_configured: true,
    workspace_ready: true
  }')"
echo "$STATE" > "$EGREGORE_DIR/.egregore-state.json"
ok ".egregore-state.json"

# ── Clone managed repos as siblings ────────────────────────────────

MANAGED_COUNT="$(jq '.repos | length' "$CONFIG" 2>/dev/null || echo 0)"
[ -z "$MANAGED_COUNT" ] && MANAGED_COUNT=0

if [ "$MANAGED_COUNT" -gt 0 ] 2>/dev/null; then
  step "Cloning managed repos"
  for i in $(seq 0 $((MANAGED_COUNT - 1))); do
    NAME="$(jq -r ".repos[$i].name // .repos[$i]" "$CONFIG" 2>/dev/null)"
    [ -z "$NAME" ] && continue
    REPO_DIR="$BASE_DIR/$NAME"
    if [ -d "$REPO_DIR/.git" ]; then
      warn "$NAME/ already exists — leaving as-is"
      configure_gh_creds "$REPO_DIR"
      continue
    fi
    if gh repo clone "$OWNER/$NAME" "$REPO_DIR" -- --quiet >/dev/null 2>&1; then
      ok "Cloned $NAME"
      configure_gh_creds "$REPO_DIR"
      set_identity "$REPO_DIR"
    else
      warn "Could not clone $OWNER/$NAME — not invited yet, or different owner"
    fi
  done
fi

# ── Shell alias ────────────────────────────────────────────────────

step "Shell alias"

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

  mkdir -p "$(dirname "$profile")" 2>/dev/null || true
  touch "$profile" 2>/dev/null || { warn "Could not write to $profile — skipping alias"; return 0; }

  local existing=""
  if grep -F -- "$dir" "$profile" >/dev/null 2>&1; then
    existing="$(grep -F -- "$dir" "$profile" | head -1 \
      | sed -nE "s/^alias ([A-Za-z_][A-Za-z0-9_-]*)[= ].*/\1/p" | head -1)"
  fi

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

SLUG="$(jq -r '.slug // empty' "$CONFIG" 2>/dev/null)"
[ -z "$SLUG" ] && SLUG="$REPO"
install_shell_alias "$EGREGORE_DIR" "$SLUG"

# ── Welcome note (if the inviter left one in memory/people/<login>.md) ──

WELCOME_FILE="$MEMORY_DIR/people/${USER_LOGIN}.md"
if [ -f "$WELCOME_FILE" ]; then
  INVITER="$(sed -nE 's/^invited_by:[[:space:]]*([^[:space:]]+).*/\1/p' "$WELCOME_FILE" | head -1 || true)"
  # Body is everything after the second `---` line
  BODY="$(awk '/^---$/{c++; next} c==2{print}' "$WELCOME_FILE" 2>/dev/null | sed '/^$/d' | head -5 || true)"
  if [ -n "$INVITER" ]; then
    echo
    if [ -n "$BODY" ]; then
      info "$INVITER invited you — \"$BODY\""
    else
      info "$INVITER invited you."
    fi
  fi
fi

# ── Telegram link (if configured) ──────────────────────────────────

if [ -n "$TELEGRAM_LINK" ]; then
  echo
  info "Join the team's Telegram group:"
  info "  $(color 36 "$TELEGRAM_LINK")"
fi

# ── Done ───────────────────────────────────────────────────────────

step "Done"

echo
ok "Joined $(bold "$ORG_NAME")"
echo
info "Workspace:"
info "  $(color 36 "$EGREGORE_DIR/")"
info "  $(color 36 "$MEMORY_DIR/")"
if [ "$MANAGED_COUNT" -gt 0 ] 2>/dev/null; then
  for i in $(seq 0 $((MANAGED_COUNT - 1))); do
    NAME="$(jq -r ".repos[$i].name // .repos[$i]" "$CONFIG" 2>/dev/null)"
    [ -n "$NAME" ] && info "  $(color 36 "$BASE_DIR/$NAME/")"
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
