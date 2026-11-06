# shellcheck shell=bash
# greeting.sh — Greeting output renderer for session-start.sh
#
# Renders the full session greeting:
#   - ASCII art banner
#   - Identity line (org/repo + user + branch)
#   - Momentum board (sessions, commits, handoffs, knowledge)
#   - Pending questions signal
#   - Health footer
#   - Alias migration
#   - Session context JSON (hidden, for Claude)
#   - Soul file inclusion
#   - Telemetry emit
#   - First session welcome
#
# Inputs:  SCRIPT_DIR, STATE_FILE, CONFIG, CTX_DIR, BRANCH, BASE_BRANCH, COMMITS_AHEAD,
#          AUTHOR, LOCAL_MODE, MEMORY_SYNCED, SAVED_BRANCH,
#          HEALTH_*, FRAMEWORK_VERSION, TIME_OF_DAY, EGREGORE_SESSION_ID,
#          FIRST_SESSION, DISPLAY_NAME_STATE, DASHBOARD_URL

# Session records reuse the index refreshed by the detached sweep.
# No transcript is opened by a greeting.
# Personal controls always win over the organization default.
_print_session_records() {
  [ -n "${HOME:-}" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  python3 - "${CONFIG:-$SCRIPT_DIR/egregore.json}" "$STATE_FILE" "$SCRIPT_DIR" \
    "${EGREGORE_MEMORY_ROOT:-$SCRIPT_DIR/memory}" "${AUTHOR:-}" <<'RECORDS_PY' 2>/dev/null || true
import datetime as dt
import json
import os
from pathlib import Path
import re
import stat
import sys

config_path, state_path, project_root, memory_root, fallback_author = sys.argv[1:]
def read_json(path):
    try:
        value = json.loads(Path(path).read_text())
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}

config = read_json(config_path)
policy = config.get("features", {}).get("session_records", {})
if not isinstance(policy, dict) or policy.get("enabled") is not True:
    raise SystemExit(0)
state = read_json(state_path)
author = state.get("github_username", fallback_author)
sys.path.insert(0, str(Path(project_root) / "bin" / "lib"))
try:
    from session_trail import instance_prefix, valid_trail_folder
    from session_record import collect_digest, metadata, sessions_directory, classify_record, Context, native_record_reader
except ImportError:
    raise SystemExit(0)
prefix = instance_prefix(project_root)
projects = Path(os.environ["HOME"]) / ".claude" / "projects"
trail_root = Path(os.environ["HOME"]) / ".egregore" / "trails" / prefix
cache = {}
cache_path = trail_root / "index.json"
try:
    if (valid_trail_folder(trail_root, projects, prefix)
            and stat.S_ISREG(cache_path.lstat().st_mode)
            and cache_path.resolve().is_relative_to(trail_root.resolve())):
        cache = read_json(cache_path)
except OSError:
    pass
today = dt.datetime.now().astimezone().date()

def clean(value):
    return re.sub(r"[\x00-\x1f\x7f]", " ", str(value)).strip()

def header(text, name):
    match = re.search(r"^\*\*" + re.escape(name) + r"\*\*:\s*(.*)$", text, re.M)
    return match.group(1).strip() if match else ""

def frontmatter(text, name):
    match = re.search(r"^" + re.escape(name) + r":\s*(.*)$", text.partition("\n---")[0], re.M)
    return match.group(1).strip().strip('"\'') if match else ""

def bullets(text, name):
    match = re.search(r"^## " + re.escape(name) + r"\s*\n(.*?)(?=^## |\Z)", text, re.M | re.S)
    return len(re.findall(r"^\s*[-*]\s+", match.group(1), re.M)) if match else 0

records = []
digest_records = []
recorded_ids = set()
scanned = 0
# Month filenames sort chronologically; a bounded newest-first scan keeps the
# greeting predictable even when an organization has years of sessions.
sessions_root = sessions_directory(memory_root)
try:
    months = sorted((p for p in sessions_root.iterdir()
                     if stat.S_ISDIR(p.lstat().st_mode)
                     and p.resolve().is_relative_to(sessions_root)), reverse=True)[:120] if sessions_root else []
except OSError:
    months = []
for month in months:
    try:
        paths = sorted(month.glob("*.md"), reverse=True)
    except OSError:
        continue
    for path in paths[:2000 - scanned]:
        scanned += 1
        try:
            if not stat.S_ISREG(path.lstat().st_mode) or not path.resolve().is_relative_to(sessions_root):
                continue
            with path.open() as source:
                text = source.read(131072)
        except (OSError, UnicodeError):
            continue
        if frontmatter(text, "kind") != "session-record":
            continue
        if state.get("session_records_noticed") is True:
            digest_records.append((path, metadata(text), text))
        if classify_record(metadata(text)) != "human-session":
            continue
        date = header(text, "Date") or frontmatter(text, "date")
        owner = header(text, "Author") or frontmatter(text, "from")
        session_id = header(text, "Session") or frontmatter(text, "session")
        if session_id:
            recorded_ids.add(session_id)
        topic = frontmatter(text, "topic")
        if not topic:
            title = re.search(r"^# (?:Session: )?(.*)$", text, re.M)
            topic = title.group(1) if title else "session"
        commits = re.search(r"\b(\d+) commits\b", text)
        records.append({"date": date, "author": owner, "topic": topic,
                        "duration": header(text, "Duration") or frontmatter(text, "duration") or "unknown",
                        "commits": int(commits.group(1)) if commits else 0,
                        "decisions": bullets(text, "Decided"), "open": bullets(text, "Open")})
    if scanned >= 2000:
        break

if state.get("session_records_noticed") is True:
    # Open items are carried by the reflex line under this block
    # (bin/reflexes/10-open-items.sh), so the digest skips the carry here.
    has_native = any(classify_record(meta) != "human-session" for _, meta, _ in digest_records)
    actor_id, reader = native_record_reader(Context(project_root)) if has_native else ("", None)
    digest = collect_digest(memory_root, author=author, person=state.get("display_name", ""),
                            days=1, today=today, records=digest_records, carry_days=0,
                            actor_id=actor_id, native_reader=reader)
    if digest["sessions"]:
        print(f"  ◦ records · yesterday {digest['sessions']} ({digest['yours']} yours) · {len(digest['decided'])} decided · {len(digest['open'])} open · /records digest")
        def short(value, limit):
            value = clean(value)
            return value if len(value) <= limit else value[:limit - 1] + "…"
        def preview(line, who):
            suffix = " — " + short(who, 40)
            print("    - " + short(line, 120 - 6 - len(suffix)) + suffix)
        for item in digest["decided"][:3]:
            preview(item["line"], item["who"])
    if digest["spirit_intents"]:
        noun = "intent" if digest["spirit_intents"] == 1 else "intents"
        print(f"  ◦ spirit records · {digest['spirit_intents']} {noun} ({digest['your_spirit_intents']} yours) · partial coverage · /records digest")
    if digest["unsupported_native"]:
        print(f"  ◦ {digest['unsupported_native']} unsupported spirit records · metadata unavailable")
    if digest["held_records"]:
        print(f"  ◦ {digest['held_records']} held records · details withheld")
    if cache.get("waiting_push"):
        print("  ◦ 1 records commit is waiting to push · /records status --push")
    raise SystemExit(0)

decider = clean(policy.get("decided_by", "your organization"))
decided_on = clean(policy.get("decided_on", ""))
personal_names = {str(value).casefold() for value in (author, state.get("display_name", "")) if value}
if str(policy.get("decided_by", "")).casefold() in personal_names:
    print(f"◇ Session records are on for {clean(config.get('github_org', ''))}/{clean(config.get('repo_name', 'egregore'))} · your decision, {decided_on}")
else:
    print(f"◇ Session records are new · {decider} turned them on for this egregore on {decided_on}")
if state.get("session_records_enabled") is False:
    print("  Your session records are off. /records on turns them back on.")
else:
    print("  Each session now leaves a record in memory/sessions: asked, decided, left open,")
    print("  touched, cost. Asks are paraphrased, never quoted. The full trail stays on this")
    model_on = policy.get("model", "haiku") != "none" and state.get("session_records_model_call") is not False
    if model_on:
        print("  machine as a file; your own Claude account reads it once to write the outline,")
        print('  through the Claude service. Say "off the record" in any session to hold it.')
    else:
        print('  machine. Say "off the record" in any session to hold it.')
    print("  /records changes yours.")
    if "unrecorded_count" in cache:
        count = int(cache.get("unrecorded_count", 0))
        try:
            days = max(0, (today - dt.date.fromisoformat(cache["oldest_date"][:10])).days)
        except (KeyError, TypeError, ValueError):
            days = int(cache.get("days", 0))
    if records:
        newest = max(records, key=lambda row: row["date"])
        if newest["author"] != author:
            print(f"  Here is one of {clean(newest['author'])}'s: {clean(newest['date'][:10])} · {clean(newest['topic'])} · {clean(newest['duration'])} · {newest['commits']} commits · {newest['decisions']} decisions · {newest['open']} open items")
    if "unrecorded_count" in cache:
        print(f"  {count} past sessions of yours are still on this machine ({days} days). Record them?")
        print("  y · show one · no")
    else:
        print("  Past sessions are being counted. The count appears at your next start.")
if cache.get("waiting_push"):
    print("  ◦ 1 records commit is waiting to push · /records status --push")
RECORDS_PY
}

# The reflexes: probes in bin/reflexes/ that each print a fact about
# yesterday, or nothing. One runner, fail-soft, shared by every startup card.
# See bin/reflexes/README.md.
_print_reflexes() {
  [ -f "$SCRIPT_DIR/bin/reflexes.sh" ] || return 0
  bash "$SCRIPT_DIR/bin/reflexes.sh" \
    --memory "${EGREGORE_MEMORY_ROOT:-$SCRIPT_DIR/memory}" \
    --author "${AUTHOR:-}" --harness "${EGREGORE_HARNESS:-claude}" 2>/dev/null || true
}

# Other startup cards reuse this records block without rendering the Claude
# greeting or running its surrounding notices and bookkeeping.
if [ "${EGREGORE_GREETING_RECORDS_ONLY:-}" = "1" ]; then
  return 0
fi

# --- Output greeting for Claude to display ---
cat << 'GREETING'

  ███████╗ ██████╗ ██████╗ ███████╗ ██████╗  ██████╗ ██████╗ ███████╗
  ██╔════╝██╔════╝ ██╔══██╗██╔════╝██╔════╝ ██╔═══██╗██╔══██╗██╔════╝
  █████╗  ██║  ███╗██████╔╝█████╗  ██║  ███╗██║   ██║██████╔╝█████╗
  ██╔══╝  ██║   ██║██╔══██╗██╔══╝  ██║   ██║██║   ██║██╔══██╗██╔══╝
  ███████╗╚██████╔╝██║  ██║███████╗╚██████╔╝╚██████╔╝██║  ██║███████╗
  ╚══════╝ ╚═════╝ ╚═╝  ╚═╝╚══════╝ ╚═════╝  ╚═════╝ ╚═╝  ╚═╝╚══════╝

GREETING

# --- Ornamented status ---
REPO_NAME=$(jq -r '.repo_name // "egregore"' "$SCRIPT_DIR/egregore.json" 2>/dev/null)
GITHUB_ORG_DISPLAY=$(jq -r '.github_org // ""' "$SCRIPT_DIR/egregore.json" 2>/dev/null)
ORG_NAME=$(jq -r '.org_name // ""' "$SCRIPT_DIR/egregore.json" 2>/dev/null)

DISPLAY_NAME=""
if [ -f "$STATE_FILE" ]; then
  DISPLAY_NAME=$(jq -r '.display_name // .name // empty' "$STATE_FILE" 2>/dev/null)
fi
GREETING_NAME="${DISPLAY_NAME:-$AUTHOR}"

# --- Line 1: Org/Repo + User + Branch (primary info) ---
SEPARATOR="  ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄"

# Build identity line: Org/repo on left, user + branch on right
if [ "$LOCAL_MODE" = "true" ]; then
  IDENTITY_LEFT="  Egregore"
else
  IDENTITY_LEFT="  ${GITHUB_ORG_DISPLAY}/${REPO_NAME}"
fi
BRANCH_COMPACT="$BRANCH"
if [ "$COMMITS_AHEAD" -gt 0 ] 2>/dev/null; then
  BRANCH_COMPACT="${BRANCH} · ${COMMITS_AHEAD}↑"
fi
IDENTITY_RIGHT="${GREETING_NAME} · ${BRANCH_COMPACT}"
LINE_WIDTH=67
ID_LEFT_LEN=${#IDENTITY_LEFT}
ID_RIGHT_LEN=${#IDENTITY_RIGHT}
ID_PADDING=$((LINE_WIDTH - ID_LEFT_LEN - ID_RIGHT_LEN))
if [ "$ID_PADDING" -lt 1 ]; then ID_PADDING=1; fi
printf "\n%s%*s%s\n" "$IDENTITY_LEFT" "$ID_PADDING" "" "$IDENTITY_RIGHT"
echo "$SEPARATOR"

# --- Momentum board ---
source "$SCRIPT_DIR/bin/lib/metrics.sh"
_render_momentum_board

# Notices remember what they already told you (bin/lib/notices.sh): open
# items say since when they have been waiting, standing state folds into one
# line after its first showing, tips expire. Set EGREGORE_NOTICE_LEDGER=off
# for a render that must not read or record.
source "$SCRIPT_DIR/bin/lib/notices.sh"
_notice_init

# Pending questions and handoffs addressed to you. These are lightweight
# discovery beats; management stays in /answer and /activity.
PENDING_Q=$(cat "$CTX_DIR/pending_questions" 2>/dev/null || echo "[]")
PENDING_Q_COUNT=$(echo "$PENDING_Q" | jq 'length' 2>/dev/null || echo "0")
if [ "$PENDING_Q_COUNT" -gt 0 ] 2>/dev/null && [ "$PENDING_Q_COUNT" != "0" ]; then
  PQ_SENDERS=$(echo "$PENDING_Q" | jq -r '[.[].from] | unique | join(", ")' 2>/dev/null)
  if [ "$PENDING_Q_COUNT" = "1" ]; then
    PQ_NOUN="question"
  else
    PQ_NOUN="questions"
  fi
  if [ -n "$PQ_SENDERS" ]; then
    PQ_LINE=$(printf "  ◐ %s pending %s from %s — /answer to engage" "$PENDING_Q_COUNT" "$PQ_NOUN" "$PQ_SENDERS")
  else
    PQ_LINE=$(printf "  ◐ %s pending %s — /answer to engage" "$PENDING_Q_COUNT" "$PQ_NOUN")
  fi
  _notice pending-questions open "questions" "$PENDING_Q_COUNT:$PQ_SENDERS" "$PQ_LINE"
fi
ADDRESSED_RICH=$(cat "$CTX_DIR/addressed_rich" 2>/dev/null || echo "[]")
ADDRESSED_COUNT=$(echo "$ADDRESSED_RICH" | jq 'length' 2>/dev/null || echo "0")
if [ "$ADDRESSED_COUNT" -gt 0 ] 2>/dev/null; then
  ADDRESSED_SIG=$(echo "$ADDRESSED_RICH" | jq -c '[.[] | (.name // .id // .)] | sort' 2>/dev/null || echo "$ADDRESSED_COUNT")
  _notice handoffs-for-you open "handoffs" "$ADDRESSED_SIG" \
    "$(printf "  ◇ %s handoffs for you — say \"show my handoffs\" to review or close" "$ADDRESSED_COUNT")"
fi

# Show auto-save notice if work was committed from a previous branch
if [ -n "$SAVED_BRANCH" ]; then
  echo "  ✓ Auto-saved uncommitted work on $SAVED_BRANCH"
fi

# --- Org-settings sync receipts. A settings.json heal is logged to
# .egregore/settings-drift.log, never announced; local settings changes reach
# the control plane through bin/settings.sh, so there is nothing to ask. ---
if [ -n "${SETTINGS_SYNCED_FROM_ORG:-}" ]; then
  echo "  ◇ org settings synced from the control plane (${SETTINGS_SYNCED_FROM_ORG})"
fi
if [ -n "${SETTINGS_POSTURE_HELD:-}" ]; then
  echo "  ◇ boundary posture was set to ${SETTINGS_POSTURE_HELD} elsewhere — relaxing access needs your confirm: bash bin/settings.sh posture ${SETTINGS_POSTURE_HELD}"
fi


_print_session_records
_print_reflexes

# --- Footer: health + repos + memory (tertiary) ---
echo "$SEPARATOR"

# One renderer for every runtime: a failed dimension names its cause and the
# action; stale recall is a separate non-failure line. See health-footer.sh.
source "$SCRIPT_DIR/bin/lib/health-footer.sh"
_render_health_footer || true

# Runtime update summary — cached durable state only, never a live probe, so
# session start stays fast. One compact line; silent when nothing is staged.
# Keyed by stable org identity composed with the main installation path
# (mirrors egregore_runtime.installation.installation_key); no org_id → no summary.
_UPGRADE_ORG=$(jq -r '.org_id // empty' "$SCRIPT_DIR/egregore.json" 2>/dev/null)
_UPGRADE_MAIN=$(cd "${MAIN_PROJECT_DIR:-$SCRIPT_DIR}" 2>/dev/null && pwd -P || true)
if [ -n "$_UPGRADE_ORG" ] && [ -n "$_UPGRADE_MAIN" ]; then
  _UPGRADE_HASH=$(printf '%s|%s' "$_UPGRADE_ORG" "$_UPGRADE_MAIN" | shasum -a 256 2>/dev/null | cut -c1-16)
  _UPGRADE_DIR="${EGREGORE_UPGRADE_ROOT:-$HOME/.egregore/runtime/upgrade}/${_UPGRADE_HASH}"
  if [ -f "$_UPGRADE_DIR/active.json" ] \
    && [ "$(jq -r '.retrieval // empty' "$_UPGRADE_DIR/active.json" 2>/dev/null)" = "runtime-qmd" ]; then
    _UPGRADE_VER=$(jq -r '.active_version // "?"' "$_UPGRADE_DIR/active.json" 2>/dev/null)
    _notice runtime-active standing "runtime ${_UPGRADE_VER##*-}" "$_UPGRADE_VER" \
      "  ◆ runtime ${_UPGRADE_VER} active · organizational retrieval: Runtime/QMD"
  elif [ -f "$_UPGRADE_DIR/state.json" ]; then
    case "$(jq -r '.status // empty' "$_UPGRADE_DIR/state.json" 2>/dev/null)" in
      preparing)
        echo "  ◐ runtime update preparing in background — egregore settings" ;;
      ready-to-activate)
        echo "  ● runtime update ready to activate — egregore settings" ;;
      failed)
        echo "  ⚠ runtime update needs attention — egregore settings" ;;
    esac
  fi
fi

# Framework update trail — an auto-update overwrites every framework path from
# upstream, local edits included. It used to surface as the footer word
# "updated" in local mode and as nothing at all in connected mode, which is not
# enough notice for files being replaced under you. Name the count, name the
# first few, and point at the commit that did it.
if [ "${FRAMEWORK_UPDATED:-false}" = "true" ] && [ "${FRAMEWORK_UPDATED_COUNT:-0}" -gt 0 ]; then
  FU_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "")
  printf "  ◆ framework updated from upstream — %s file(s) replaced: %s\n" \
    "$FRAMEWORK_UPDATED_COUNT" "${FRAMEWORK_UPDATED_FILES% }"
  if [ -n "$FU_SHA" ]; then
    printf "    local edits to framework paths are replaced by design — git show %s\n" "$FU_SHA"
  fi
fi

# Autosave trail — background saves (Stop-hook, sweep, SessionEnd) since the
# last greeting. The ledger is machine-scoped; this is where sweep rescues of
# abandoned sessions become visible to the user.
AUTOSAVE_LOG="${EGREGORE_AUTOSAVE_LOG:-$HOME/.egregore/autosave.log}"
AUTOSAVE_SEEN="${AUTOSAVE_LOG}.seen"
if [ -f "$AUTOSAVE_LOG" ]; then
  TOTAL_AS=$(grep -c '|autosave|' "$AUTOSAVE_LOG" 2>/dev/null || echo 0)
  SEEN_AS=$(cat "$AUTOSAVE_SEEN" 2>/dev/null || echo 0)
  case "$SEEN_AS" in ''|*[!0-9]*) SEEN_AS=0 ;; esac
  if [ "$TOTAL_AS" -gt "$SEEN_AS" ]; then
    NEW_AS=$((TOTAL_AS - SEEN_AS))
    MERGED_AS=$(grep '|autosave|' "$AUTOSAVE_LOG" 2>/dev/null | tail -n "$NEW_AS" | grep -c '|merged|' || echo 0)
    if [ "$MERGED_AS" -gt 0 ]; then
      printf "  ⟲ auto-saved %s non-coding save(s) → develop while you were away\n" "$MERGED_AS"
    fi
  fi
  printf '%s' "$TOTAL_AS" > "$AUTOSAVE_SEEN" 2>/dev/null || true
fi

# Staged auto-saves awaiting the user's merge (the /autosave consent gate).
# Live gh query so the line persists until the PRs actually merge — the
# ledger cursor above only reports once. Fail-soft when gh/network is out.
# Shown only while the autosave experiment is enabled: stale PRs from a
# disabled experiment should not nag every greeting.
AUTOSAVE_ON=$(jq -r '.autosave_enabled // false' "$STATE_FILE" 2>/dev/null)
if [ "$AUTOSAVE_ON" = "true" ] && command -v gh >/dev/null 2>&1; then
  GH_SELF=$(jq -r '.github_username // empty' "$STATE_FILE" 2>/dev/null)
  if [ -n "$GH_SELF" ]; then
    WAITING_AS=$(gh pr list --state open --author "$GH_SELF" --limit 20 \
      --json number,title --jq '[.[] | select(.title | startswith("Auto-save:")) | .number] | join(", #")' 2>/dev/null || true)
    if [ -n "$WAITING_AS" ]; then
      printf "  ⟲ auto-saves awaiting your merge: PR #%s — say \"merge my auto-saves\"\n" "$WAITING_AS"
    fi
  fi
fi

# Greeting links. Org config `pinned_links` in egregore.json replaces the
# default dashboard + board links. Entries are strings or {url, label}.
# (OSC 8 hyperlink — clickable text in supported terminals)
PINNED_LINKS=$(jq -c '.pinned_links // []' "${CONFIG:-$SCRIPT_DIR/egregore.json}" 2>/dev/null || echo "[]")
if [ "$(printf '%s' "$PINNED_LINKS" | jq 'length' 2>/dev/null || echo 0)" -gt 0 ]; then
  # Each pinned link is a standing notice keyed by its position: full line on
  # first sight or change, folded under its label afterwards.
  _notice_pinned_links "$PINNED_LINKS"
else
  if [ -n "${DASHBOARD_URL:-}" ]; then
    _notice dashboard-link standing "dashboard" "$DASHBOARD_URL" "  ◆ $DASHBOARD_URL"
  fi

  if [ -n "${BOARD_URL:-}" ]; then
    _notice board-link standing "board" "$BOARD_URL" "  ◆ $BOARD_URL (board)"
  fi
fi

if [ -n "${LOOM_DOCTOR_BRIEF:-}" ]; then
  # Indent every line — printf '  %s' indents only the first line of a
  # multiline brief, which misaligns the card and hides follow-up warnings
  # from the fast-path signal-line scraper (it keys on "^  ").
  # A standing notice: the brief is deterministic for a given config, so an
  # unchanged brief folds after its first showing instead of repeating.
  LOOM_LABEL=$(printf '%s\n' "$LOOM_DOCTOR_BRIEF" | head -1 | sed 's/^[⚠◆] *//; s/ (.*$//')
  _notice loom-doctor standing "$LOOM_LABEL" "$LOOM_DOCTOR_BRIEF" \
    "$(printf '%s\n' "$LOOM_DOCTOR_BRIEF" | sed 's/^/  /')"
fi

# --- Creator review gate: pending turns on owned scrolls/surfaces ---
# This is deliberately filesystem-only and fail-soft. The two environment seams
# make the scan safe to exercise without touching the instance memory repo.
_print_pending_scroll_turns() {
  # Empty event directories are normal. Match Bash's literal unmatched globs
  # for this function only; never change the caller's Zsh options.
  if [ -n "${ZSH_VERSION:-}" ]; then setopt local_options nonomatch; fi
  local memory_root="${EGREGORE_MEMORY_ROOT:-$SCRIPT_DIR/memory}"
  local person="${EGREGORE_PERSON:-${AUTHOR:-}}"
  local rows="" file slug owner count surface_file

  if [ -z "$person" ] && [ -f "${STATE_FILE:-}" ]; then
    person=$(jq -r '.github_username // .display_name // .name // empty' "$STATE_FILE" 2>/dev/null || true)
  fi
  [ -n "$person" ] || return 0
  [ -d "$memory_root" ] || return 0

  for file in "$memory_root"/scrolls/.events/*.jsonl; do
    [ -f "$file" ] || continue
    slug=$(basename "$file" .jsonl)
    [[ "$slug" =~ ^[A-Za-z0-9._-]+$ ]] || continue
    safe_slug=$(printf '%s' "$slug" | tr -d '\000-\037\177')
    [ "$safe_slug" = "$slug" ] || continue
    owner=$(sed -nE 's/^[[:space:]-]*(\*\*)?creator(\*\*)?[[:space:]]*:[[:space:]]*//p' "$memory_root/scrolls/$slug.md" 2>/dev/null | head -1 | sed 's/[[:space:]]*$//')
    [ "$owner" = "$person" ] || continue
    count=$(jq -s -r '
      def event_id:
        if (.turn | type) == "object" then .turn.id
        elif (.turn | type) == "string" then .turn
        else .id end;
      def received($events):
        [$events[] | select(.type == "turn-received")
          | {id: event_id, answers: (.turn.answers // .answers // [])}
          | select(.id != null)] | unique_by(.id);
      def review_id: event_id;
      def is_absorbed($events; $id):
        any($events[]; .type == "version-published" and ((.absorbs // .version.absorbs // .record.absorbs // []) | index($id) != null));
      def is_applied($events; $id):
        any($events[]; .type == "turn-applied" and (event_id == $id));
      def is_declined($events; $received; $id):
        ([$received[] | select(.id == $id)] | .[0]) as $turn |
        ([$events[] | select(.type == "turn-reviewed" and review_id == $id)] | .[0]) as $review |
        if $review == null then false
        else if (($turn.answers // []) | length) == 0 then $review.disposition == "declined"
        else (($turn.answers // [])
          | map(($review.answers // {})[.fork] // $review.disposition)
          | map(select(. == "accepted")) | length) == 0
        end
        end;
      . as $events
      | ($events | received($events)) as $received
      | [$received[] as $turn
          | select((is_absorbed($events; $turn.id) | not))
          | select((is_declined($events; $received; $turn.id) | not))
          | select(if $mode == "scroll" then true else (is_applied($events; $turn.id) | not) end)]
      | length
    ' --arg mode scroll "$file" 2>/dev/null) || continue
    [[ "$count" =~ ^[0-9]+$ ]] || continue
    [ "$count" -gt 0 ] && rows+="${safe_slug}"$'\t'"${count}"$'\n'
  done

  for file in "$memory_root"/harvests/.events/*.jsonl; do
    [ -f "$file" ] || continue
    slug=$(basename "$file" .jsonl)
    [[ "$slug" =~ ^[A-Za-z0-9._-]+$ ]] || continue
    safe_slug=$(printf '%s' "$slug" | tr -d '\000-\037\177')
    [ "$safe_slug" = "$slug" ] || continue
    surface_file="$memory_root/harvests/$slug.json"
    [ -f "$surface_file" ] || continue
    owner=$(jq -r '.author // empty' "$surface_file" 2>/dev/null) || continue
    [ "$owner" = "$person" ] || continue
    count=$(jq -s -r '
      def event_id:
        if (.turn | type) == "object" then .turn.id
        elif (.turn | type) == "string" then .turn
        else .id end;
      def received($events):
        [$events[] | select(.type == "turn-received")
          | {id: event_id, answers: (.turn.answers // .answers // [])}
          | select(.id != null)] | unique_by(.id);
      def review_id: event_id;
      def is_absorbed($events; $id): false;
      def is_applied($events; $id):
        any($events[]; .type == "turn-applied" and (event_id == $id));
      def is_declined($events; $received; $id):
        ([$received[] | select(.id == $id)] | .[0]) as $turn |
        ([$events[] | select(.type == "turn-reviewed" and review_id == $id)] | .[0]) as $review |
        if $review == null then false
        else if (($turn.answers // []) | length) == 0 then $review.disposition == "declined"
        else (($turn.answers // [])
          | map(($review.answers // {})[.fork] // $review.disposition)
          | map(select(. == "accepted")) | length) == 0
        end
        end;
      . as $events
      | ($events | received($events)) as $received
      | [$received[] as $turn
          | select((is_applied($events; $turn.id) | not))
          | select((is_declined($events; $received; $turn.id) | not))]
      | length
    ' --arg mode harvest "$file" 2>/dev/null) || continue
    [[ "$count" =~ ^[0-9]+$ ]] || continue
    [ "$count" -gt 0 ] && rows+="${safe_slug}"$'\t'"${count}"$'\n'
  done

  [ -n "$rows" ] || return 0
  local summary total details
  summary=$(printf '%s' "$rows" | awk -F '\t' 'NF == 2 { totals[$1] += $2 } END { for (slug in totals) print slug "\t" totals[slug] }' | sort -t $'\t' -k1,1) || return 0
  [ -n "$summary" ] || return 0
  total=$(printf '%s\n' "$summary" | awk -F '\t' '{ total += $2 } END { print total + 0 }') || return 0
  details=$(printf '%s\n' "$summary" | awk -F '\t' '{printf "%s%s (%s)", (NR == 1 ? "" : ", "), $1, $2}') || return 0
  [ -n "$details" ] || return 0
  _notice scroll-turns open "scroll turns" "$total:$details" \
    "$(printf "  ⧖ %s pending turn(s) on your scrolls: %s" "$total" "$details")"
}

_print_pending_scroll_turns

# Fold the standing notices that did not change since last session into one
# line, and persist the ledger. The tutorial tip below is recorded by the
# second flush at the end of the file.
_notice_flush

# Framework updates come through PRs to develop — no separate auto-update channel.
# The develop sync above already keeps framework files current.
# Use /update for manual upstream pulls when needed.

# --- One-time migration: fix aliases to use 'claude "start"' ---
# v1: 'claude start' → 'claude' (cross-instance bug)
# v2: 'claude' → 'claude "start"' (blank prompt — auto-sends first message)
ALIAS_VERSION=$(jq -r '.alias_version // 0' "$STATE_FILE" 2>/dev/null || echo "0")
if [ "$ALIAS_VERSION" -lt 2 ] 2>/dev/null; then
  for profile in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile"; do
    if [ -f "$profile" ] && grep -q "$SCRIPT_DIR" "$profile" 2>/dev/null; then
      # Replace any egregore alias pointing to this directory with the correct command
      # Handles: && claude start, && claude, && claude "start" (idempotent)
      sed -i.bak "s|&& claude start|\\&\\& claude \"start\"|g; s|&& claude'|\\&\\& claude \"start\"'|g" "$profile" 2>/dev/null && rm -f "${profile}.bak" || true
    fi
  done
  if [ -f "$STATE_FILE" ] && jq . "$STATE_FILE" >/dev/null 2>&1; then
    jq '. + {"alias_fixed": true, "alias_version": 2}' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
  fi
fi

# --- Card close: first-session welcome or tutorial tip (visible) ---
# Everything the user should see renders before the hidden context below, so
# a harness that displays the card directly (bin/lib/card-delivery.sh) shows
# all of it. In that mode the card also asks the opening question itself,
# the same way bin/codex-session-start.sh ends the Codex and Pi card.
if [ -z "$FIRST_SESSION" ] && [ -f "$STATE_FILE" ]; then
  FIRST_SESSION=$(jq -r '.first_session // false' "$STATE_FILE" 2>/dev/null)
fi

if [ "$FIRST_SESSION" = "true" ]; then
  echo ""
  echo "  Welcome! This is your first session."
  if [ "${EGREGORE_CARD_DELIVERY:-text}" = "harness" ]; then
    echo ""
    echo "  Want a quick tour first (/onboarding), or jump straight in?"
  fi
  # Clear the flag so it only shows once
  jq '.first_session = false' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
else
  # --- Tutorial tip (if onboarding done but tutorial not) ---
  TUTORIAL_COMPLETE="true"
  if [ -f "$STATE_FILE" ]; then
    TUTORIAL_COMPLETE=$(jq -r '.tutorial_complete // false' "$STATE_FILE" 2>/dev/null || echo "true")
  fi

  if [ "$TUTORIAL_COMPLETE" != "true" ]; then
    # A tip that has not been acted on after a few sessions is noise; the
    # ledger retires it after NOTICE_TIP_MAX showings.
    _notice tutorial-tip tip "tutorial" "tutorial" "  Tip: Run /tutorial to learn the core loop."
  fi
  _notice_flush
  if [ "${EGREGORE_CARD_DELIVERY:-text}" = "harness" ]; then
    echo ""
    echo "  What are you working on?"
  fi
fi

echo ""

# --- Session context (hidden, for Claude) ---
CONTEXT_HANDOFFS=$(cat "$CTX_DIR/handoffs" 2>/dev/null || echo "[]")
CONTEXT_HANDOFFS=$(printf '%s' "$CONTEXT_HANDOFFS" | jq -c 'map(if .preview then .preview |= .[0:80] else . end)' 2>/dev/null || printf '%s' "$CONTEXT_HANDOFFS")
CONTEXT_ADDRESSED=$(cat "$CTX_DIR/addressed" 2>/dev/null || echo "[]")
CONTEXT_QUESTS=$(cat "$CTX_DIR/quests" 2>/dev/null || echo "[]")
CONTEXT_QUESTS=$(printf '%s' "$CONTEXT_QUESTS" | jq -c 'if length > 20 then .[0:20] + ["+\(length - 20) more"] else . end' 2>/dev/null || printf '%s' "$CONTEXT_QUESTS")
CONTEXT_ACTIVITY=$(cat "$CTX_DIR/activity" 2>/dev/null || echo "")
CONTEXT_TEAM=$(cat "$CTX_DIR/team" 2>/dev/null || echo "[]")
# Trim the team blob for greeting injection: 8 most-recent people, drop sort
# keys, one branch each. This trimmed view is all the session ever sees —
# CTX_DIR is deleted at the end of this script — a deliberate cap to keep
# hook stdout inline-sized. Untrimmed this is the single largest field in
# session-context.
CONTEXT_TEAM=$(printf '%s' "$CONTEXT_TEAM" | jq -c '.[0:8] | map({name, last_seen, working_on: ((.working_on // "")[0:80]), branches: ((.branches // [])[0:1])})' 2>/dev/null || printf '%s' "$CONTEXT_TEAM")
CONTEXT_SOUL=$(cat "$CTX_DIR/soul_summary" 2>/dev/null || echo "")
CONTEXT_LIFECYCLE=$(cat "$CTX_DIR/lifecycle" 2>/dev/null || echo '{"merged_prs":[],"implemented_handoffs":[]}')
CONTEXT_PULSE=$(cat "$CTX_DIR/pulse_brief" 2>/dev/null || echo '{}')
if [ -f "$CTX_DIR/metrics" ]; then
  CONTEXT_METRICS=$(jq -c . "$CTX_DIR/metrics" 2>/dev/null || echo "{}")
  [ -n "$CONTEXT_METRICS" ] || CONTEXT_METRICS="{}"
else
  CONTEXT_METRICS="{}"
fi

# --- Write compact subagent context cache (reuses already-gathered data) ---
SUBAGENT_CTX="/tmp/egregore-subagent-ctx-${EGREGORE_SESSION_ID}.txt"
(
  SA_ORG_NAME=$(jq -r '.org_name // "Unknown"' "$SCRIPT_DIR/egregore.json" 2>/dev/null || echo "Unknown")
  SA_GITHUB_ORG=$(jq -r '.github_org // "unknown"' "$SCRIPT_DIR/egregore.json" 2>/dev/null || echo "unknown")

  # Format quests list
  SA_QUESTS="none"
  if [ "$CONTEXT_QUESTS" != "[]" ]; then
    SA_QUESTS=$(echo "$CONTEXT_QUESTS" | jq -r '.[]' 2>/dev/null | paste -sd', ' - 2>/dev/null || echo "none")
  fi

  # Format recent handoffs
  SA_HANDOFFS="none"
  if [ "$CONTEXT_HANDOFFS" != "[]" ]; then
    SA_HANDOFFS=$(echo "$CONTEXT_HANDOFFS" | jq -r '.[] | .name' 2>/dev/null | head -5 | paste -sd', ' - 2>/dev/null || echo "none")
  fi

  cat > "$SUBAGENT_CTX" << SAEOF
<!-- egregore-context
Organization: $SA_ORG_NAME (github: $SA_GITHUB_ORG)
Session: $BRANCH — ${EGREGORE_SESSION_ID}
Active quests: $SA_QUESTS
Recent handoffs: $SA_HANDOFFS
Memory: memory/ holds canonical organizational knowledge. Use bin/search.sh for Runtime/QMD retrieval.
-->
SAEOF
) 2>/dev/null || true

# Emit the context JSON compacted (jq -c) — nested blobs arrive pretty-printed
# from CTX_DIR and the whitespace alone is ~1KB of hook stdout. Fall back to
# the raw heredoc if jq can't parse (a malformed fragment must not eat context).
_CTX_JSON=$(cat << CTXEOF
{
  "framework_version": "$FRAMEWORK_VERSION",
  "time_of_day": "$TIME_OF_DAY",
  "dashboard_url": "${DASHBOARD_URL:-}",
  "recent_handoffs": $CONTEXT_HANDOFFS,
  "addressed_to_user": $CONTEXT_ADDRESSED,
  "quests": $CONTEXT_QUESTS,
  "last_user_activity": "$CONTEXT_ACTIVITY",
  "team_recent_memory": $CONTEXT_TEAM,
  "soul_self_summary": "$CONTEXT_SOUL",
  "lifecycle": $CONTEXT_LIFECYCLE,
  "momentum": $CONTEXT_METRICS,
  "pulse": $CONTEXT_PULSE
}
CTXEOF
)
printf '\n<!-- session-context\n%s\n-->\n' \
  "$(printf '%s' "$_CTX_JSON" | jq -c . 2>/dev/null || printf '%s' "$_CTX_JSON")"

# Include soul file if present
if [ -f "$SCRIPT_DIR/egregore.md" ]; then
  echo ""
  echo "<!-- egregore-soul"
  cat "$SCRIPT_DIR/egregore.md"
  echo "-->"
fi

# Point at the latest soul reflection instead of inlining it. The full
# document is several KB; injected verbatim it pushed hook stdout past the
# harness inline threshold, which turns the greeting into a file the model
# must Read back — a whole extra API round-trip on every boot.
if [ -d "$SCRIPT_DIR/memory/soul" ]; then
  LATEST_REFLECTION=$(ls -t "$SCRIPT_DIR/memory/soul/"*.md 2>/dev/null | head -1 || true)
  if [ -n "$LATEST_REFLECTION" ]; then
    echo "<!-- latest-reflection: memory/soul/$(basename "$LATEST_REFLECTION") — read when org identity, culture, or history context matters -->"
  fi
fi

# --- Flush leftover telemetry from previous session (background) ---
# If the previous session exited without a clean flush (terminal closed,
# crash, kill -9), events are still in the local buffer. Drain them now.
bash "$SCRIPT_DIR/bin/telemetry.sh" flush 2>/dev/null &

# --- Emit session_start telemetry (background, non-blocking) ---
bash "$SCRIPT_DIR/bin/telemetry.sh" emit "session_start" \
  "$(jq -n --arg branch "$BRANCH" '{branch: $branch}')" 2>/dev/null &

# --- Health check-in (background, non-blocking) ---
bash "$SCRIPT_DIR/bin/startup-check.sh" >/dev/null 2>&1 &

# Artifact dependencies are provisioned during explicit setup/update. Startup
# must not warm a floating npx cache that the offline renderer cannot resolve.

# Clean up temp files
rm -rf "$CTX_DIR"

# --- Instruction for the model ---
# Harness delivery: the user already sees the scripted card, question
# included, so the model must not retype it. Text delivery (a harness that
# cannot display hook output directly) keeps the display instruction. The
# branch rule that used to follow is gone: CLAUDE.md's "Before Project
# Changes" section is the one branching contract.
echo ""
if [ "${EGREGORE_CARD_DELIVERY:-text}" = "harness" ]; then
  if [ "$FIRST_SESSION" = "true" ]; then
    echo "STARTUP CARD: The harness has already shown the user the startup card above, ending with an offer of a quick tour (/onboarding). Do not reprint, summarize, or narrate it. Treat the user's first message as their answer."
  else
    echo "STARTUP CARD: The harness has already shown the user the startup card above, ending with \"What are you working on?\". Do not reprint, summarize, or narrate it. Treat the user's first message as the answer. If it carries no request (the launcher submits \`start\` automatically), reply with one short line and no tool calls."
  fi
elif [ "$FIRST_SESSION" = "true" ]; then
  echo "IMPORTANT: Display the above greeting exactly as-is (ASCII art + ornamented status). Then ask the user if they'd like a quick onboarding tour (run /onboarding), or if they want to jump straight in."
else
  echo "IMPORTANT: Display the above greeting to the user exactly as-is (preserve the ASCII art formatting and ornamented status) on their first message. Then ask: What are you working on?"
fi
