#!/usr/bin/env bash
# Exercise the real renderer in an offline fixture; no startup or real memory.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$REPO_ROOT/tmp"
ROOT="$(mktemp -d "$REPO_ROOT/tmp/greeting-records.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
python3 - "$REPO_ROOT" "$ROOT" <<'PY'
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import sys
import time

repo, fixture = map(Path, sys.argv[1:])
sys.path.insert(0, str(repo / "bin/lib"))
import budget  # noqa: E402  (a contract on a laptop, a reading with a ceiling on a shared runner)
project = fixture / "project"
home = fixture / "home"
memory = project / "memory"
for directory in [project / "bin/lib", home, memory / "sessions", fixture / "fake-bin", fixture / "tmp"]:
    directory.mkdir(parents=True, exist_ok=True)
for name in ["greeting.sh", "metrics.sh", "notices.sh", "health-footer.sh", "config.sh", "session_trail.py"]:
    shutil.copy2(repo / "bin/lib" / name, project / "bin/lib" / name)
# The settings entry point can use Python implementation helpers without
# teaching this fixture their names. No executable is invoked from the source.
for path in (repo / "bin/lib").glob("*record*.py"):
    shutil.copy2(path, project / "bin/lib" / path.name)
# Public read/classification works without the private native writer.
shutil.copytree(repo / "egregore_runtime", project / "egregore_runtime",
                ignore=shutil.ignore_patterns("__pycache__", "record_admission.py"))
if (repo / "bin/records.sh").exists():
    shutil.copy2(repo / "bin/records.sh", project / "bin/records.sh")
shutil.copy2(repo / "bin/codex-session-start.sh", project / "bin/codex-session-start.sh")
# Exercise the real Codex card with startup integrations stubbed inside the
# fixture. In particular no Git command, background publication, or live
# context source can escape into the developer's repositories.
for name in ["hash", "time", "identity", "git-sync"]:
    (project / "bin/lib" / f"{name}.sh").write_text(":\n")
(project / "bin/lib/context.sh").write_text('CTX_DIR="$(mktemp -d "$TMPDIR/codex-context.XXXXXX")"\n')
for name in ["telemetry", "startup-check", "scratch-sweep", "node-run",
             "session-autosave", "connect-refresh", "session-record"]:
    (project / "bin" / f"{name}.sh").write_text("#!/bin/sh\nexit 0\n")
for name in ["npx", "npm", "qmd", "gh", "curl", "wget", "claude", "git"]:
    path = fixture / "fake-bin" / name
    path.write_text("#!/bin/sh\nexit 97\n")
    path.chmod(0o755)
config_path = project / "egregore.json"
state_path = project / ".egregore-state.json"
config = {"mode": "local", "org_name": "Records fixture", "github_org": "fixture",
          "repo_name": "egregore", "features": {"session_records": {
              "enabled": True, "model": "haiku", "retroactive_days": 90,
              "decided_by": "cem", "decided_on": "2026-10-15"}}}
state = {"github_username": "cem", "display_name": "Cem", "alias_version": 2,
         "tutorial_complete": True}

def write_settings():
    config_path.write_text(json.dumps(config))
    state_path.write_text(json.dumps(state))

sys.path.insert(0, str(project / "bin/lib"))
from session_trail import instance_prefix
prefix = instance_prefix(project)
trails = home / ".egregore/trails" / prefix
trails.mkdir(parents=True)
projects = home / ".claude/projects"
now = dt.datetime.now().astimezone()
for index, folder_name in enumerate([prefix, prefix, prefix + "--claude-worktrees-example"]):
    folder = projects / folder_name
    folder.mkdir(parents=True, exist_ok=True)
    start = now - dt.timedelta(days=index + 1)
    path = folder / f"session-{index}.jsonl"
    path.write_text("\n".join(json.dumps(line) for line in [
        {"type": "user", "sessionId": f"session-{index}", "timestamp": start.isoformat(),
         "message": {"role": "user", "content": "Discuss the fixture"}},
        {"type": "assistant", "timestamp": (start + dt.timedelta(minutes=10)).isoformat(),
         "message": {"role": "assistant", "model": "haiku", "content": [{"type": "text", "text": "Fixture reply"}]}}
    ]) + "\n")
    os.utime(path, (start.timestamp(), start.timestamp()))
other = projects / (prefix + "-new")
other.mkdir()
(other / "outside.jsonl").write_text("unrelated")

base_env = {k: v for k, v in os.environ.items() if not k.startswith(("EGREGORE_", "QMD_", "GIT_"))}
base_env.update({"HOME": str(home), "TMPDIR": str(fixture / "tmp"),
                "PATH": str(fixture / "fake-bin") + os.pathsep + os.environ["PATH"],
                "SCRIPT_DIR": str(project), "CONFIG": str(config_path), "STATE_FILE": str(state_path),
                "BRANCH": "records-fixture", "BASE_BRANCH": "develop", "COMMITS_AHEAD": "0",
                "AUTHOR": "cem", "LOCAL_MODE": "true", "MEMORY_SYNCED": "true", "SAVED_BRANCH": "",
                "REPOS_STATUS": "", "HEALTH_GITHUB": "ok", "HEALTH_GIT": "ok", "HEALTH_APIKEY": "skip",
                "HEALTH_GRAPH": "skip", "HEALTH_TELEGRAM": "skip", "FRAMEWORK_VERSION": "6",
                "TIME_OF_DAY": "day", "EGREGORE_SESSION_ID": f"greeting-records-{os.getpid()}",
                "FIRST_SESSION": "", "DISPLAY_NAME_STATE": "", "DASHBOARD_URL": "", "BOARD_URL": "",
                "LOOM_DOCTOR_BRIEF": "", "EGREGORE_NOTICE_LEDGER": "off", "EGREGORE_NO_TELEMETRY": "1",
                "XDG_CACHE_HOME": str(home / ".cache"), "XDG_CONFIG_HOME": str(home / ".config"),
                "XDG_DATA_HOME": str(home / ".local/share")})
count = 0

audit_dir = fixture / "audit-python"
audit_dir.mkdir()
audit_log = fixture / "transcript-opens"
(audit_dir / "sitecustomize.py").write_text(r'''import builtins
import io
import os
original_builtin_open = builtins.open
original_io_open = io.open
roots = tuple(os.path.join(os.environ["HOME"], path) for path in
              (".codex/sessions", ".claude/projects", ".pi/agent/sessions", ".prime/agent/sessions"))
def audit_open(original, file, *args, **kwargs):
    if isinstance(file, (str, bytes, os.PathLike)):
        path = os.fsdecode(file)
        if any(path.startswith(root + os.sep) and path.endswith(".jsonl") for root in roots):
            with original_builtin_open(os.environ["TRANSCRIPT_OPEN_LOG"], "a") as log:
                log.write(path + "\n")
            raise AssertionError("a greeting must never open a transcript")
    return original(file, *args, **kwargs)
builtins.open = lambda file, *a, **kw: audit_open(original_builtin_open, file, *a, **kw)
io.open = lambda file, *a, **kw: audit_open(original_io_open, file, *a, **kw)
''')

def greeting(shell="bash", audit=False):
    write_settings()
    ctx = fixture / f"context-{time.monotonic_ns()}"
    ctx.mkdir()
    env = dict(base_env, CTX_DIR=str(ctx), AUTHOR=state["github_username"])
    if audit:
        env.update(PYTHONPATH=str(audit_dir), TRANSCRIPT_OPEN_LOG=str(audit_log))
    started = time.monotonic()
    result = subprocess.run([shell, str(project / "bin/lib/greeting.sh")], env=env,
                            cwd=project, capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stderr
    assert "Display the above greeting" in result.stdout, "greeting did not finish"
    return result.stdout, time.monotonic() - started

def sweep_count(expected):
    write_settings()
    cache_path = trails / "index.json"
    cache_path.unlink(missing_ok=True)
    result = subprocess.run([sys.executable, str(project / "bin/lib/session_record.py"),
                             "record", "--root", str(project), "--mode", "sweep", "--force"],
                            env=base_env, cwd=project, capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stderr
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if cache_path.exists():
            cache = json.loads(cache_path.read_text())
            if cache.get("unrecorded_count") == expected:
                return cache
        time.sleep(0.05)
    raise AssertionError(f"sweep did not cache {expected} eligible sessions: " +
                         (cache_path.read_text() if cache_path.exists() else "no cache"))

def codex_card(entry="codex-session-start.sh"):
    write_settings()
    result = subprocess.run(["bash", str(project / "bin" / entry), "--card"],
                            cwd=project, env=base_env, capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stderr
    assert "What are you working on?" in result.stdout, result.stdout
    return result.stdout

def check(name, condition):
    global count
    assert condition, name
    count += 1
    print("PASS: " + name, flush=True)

def record(name, author, when, decisions, opened, commits=2, open_lines=None):
    folder = memory / "sessions" / when.strftime("%Y-%m")
    folder.mkdir(exist_ok=True)
    path = folder / (name + ".md")
    path.write_text(f'''---
kind: session-record
from: "{author}"
date: {when.date().isoformat()}
topic: "fixture planning"
status: final
---
# Session: fixture planning

**Date**: {when.isoformat()}
**Author**: {author}
**Session**: {name}
**Duration**: 20m

## Summary
20m on fixture planning; {commits} commits, 3 files, 0 recalls (0 failed); $0.25

## Decided
''' + "\n".join(f"- Decision {i} — {author}, 10:00" for i in range(decisions)) +
                    "\n\n## Open\n" + "\n".join("- " + line for line in
                        (open_lines if open_lines is not None else [f"Item {i}" for i in range(opened)])) + "\n\n## Cost\n$0.25\n")
    return path

try:
    output, _ = greeting()
    check("first block appears once without an uncached count",
          output.count("◇ Session records are on for fixture/egregore · your decision, 2026-10-15") == 1
          and "Past sessions are being counted. The count appears at your next start." in output
          and "past sessions of yours" not in output and "your own Claude account reads it once" in output)
    check("records block precedes the status footer rule",
          output.index("◇ Session records") < output.index("  ┄", output.index("◇ Session records")))
    codex_dir = home / ".codex/sessions/2020/01/01"
    codex_dir.mkdir(parents=True)
    codex_start = now - dt.timedelta(days=1)
    def rollout(name, originator="codex-tui", source="cli", prompt=True):
        path = codex_dir / f"rollout-{name}.jsonl"
        entries = [{"type": "session_meta", "timestamp": codex_start.isoformat(), "payload": {
            "id": name, "session_id": name, "cwd": str(project), "originator": originator,
            "source": source, "timestamp": codex_start.isoformat()}}]
        if prompt:
            entries.append({"type": "event_msg", "timestamp": codex_start.isoformat(), "payload": {
                "type": "item_completed", "item": {"type": "UserMessage", "content": [
                    {"type": "Text", "text": "Review fixture coverage"}]}}})
        entries.append({"type": "event_msg", "timestamp": (codex_start + dt.timedelta(minutes=10)).isoformat(),
                        "payload": {"type": "task_complete", "duration_ms": 600000}})
        path.write_text("\n".join(map(json.dumps, entries)) + "\n")
        os.utime(path, (codex_start.timestamp(), codex_start.timestamp()))
        return path
    codex_files = [rollout(f"codex-count-{index}") for index in range(50)]
    output, _ = greeting(audit=True)
    check("uncached greeting opens no transcript in a 50-rollout tree and shows no number",
          not audit_log.exists() and "Past sessions are being counted." in output
          and "past sessions of yours" not in output)
    codex_files.extend([rollout("companion", originator="Claude Code", source="vscode"),
                        rollout("exec", source="exec"), rollout("no-prompts", prompt=False)])
    sweep_count(54)
    output, _ = greeting(audit=True)
    check("detached sweep supplies a count including old-folder Codex activity",
          "54 past sessions of yours" in output and not audit_log.exists())
    check("greeting upper bound excludes companion and exec but retains zero-prompt human threads",
          "56 past sessions" not in output and "54 past sessions of yours" in output)
    check("counting before the offer is answered publishes nothing",
          not list((memory / "sessions").glob("*/*.md")))
    for path in codex_files:
        path.unlink()
    sweep_count(3)
    output = codex_card()
    check("Codex card renders the shared first-time offer once after its card",
          output.count("◇ Session records are on") == 1 and "3 past sessions of yours" in output
          and output.index("What are you working on?") < output.index("◇ Session records"))
    state["github_username"] = "fcdagdelen"
    state["display_name"] = "cem"
    output, _ = greeting()
    check("decider display name matches the current person's different handle",
          "◇ Session records are on for fixture/egregore · your decision, 2026-10-15" in output)
    state["display_name"] = "CEM"
    output, _ = greeting()
    check("decider identity matching ignores case",
          "◇ Session records are on for fixture/egregore · your decision, 2026-10-15" in output)
    state["github_username"] = "other"
    state["display_name"] = "Other"
    output, _ = greeting()
    check("other author sees the organization decision wording",
          "◇ Session records are new · cem turned them on for this egregore on 2026-10-15" in output)
    state["github_username"] = "cem"
    state["display_name"] = "Cem"
    foreign_trails = home / ".egregore/trails/foreign-instance"
    (foreign_trails / "holds").mkdir(parents=True)
    (foreign_trails / "holds/session-2").write_text("held elsewhere")
    (foreign_trails / "index.json").write_text(json.dumps({"unrecorded_count": 900, "waiting_push": True}))
    alias_trails = trails.parent / (prefix + "--claude-worktrees-example")
    alias_trails.symlink_to(foreign_trails, target_is_directory=True)
    output, _ = greeting()
    check("symlinked trail alias cannot supply foreign holds or cached counts",
          "3 past sessions of yours" in output and "900 past sessions" not in output
          and "records commit is waiting to push" not in output)
    alias_trails.unlink()
    cache_path = trails / "index.json"
    cache_path.unlink()
    cache_path.symlink_to(foreign_trails / "index.json")
    output, _ = greeting()
    check("symlinked greeting cache is refused without reading transcripts",
          "Past sessions are being counted." in output and "900 past sessions" not in output
          and "records commit is waiting to push" not in output)
    cache_path.unlink()
    local_cache_target = trails / "other-index.json"
    local_cache_target.write_text(json.dumps({"unrecorded_count": 800, "waiting_push": True}))
    cache_path.symlink_to(local_cache_target)
    output, _ = greeting()
    check("greeting cache must be a regular entry even when its symlink target is local",
          "Past sessions are being counted." in output and "800 past sessions" not in output
          and "records commit is waiting to push" not in output)
    cache_path.unlink()
    local_cache_target.unlink()
    yesterday = now - dt.timedelta(days=1)
    other_record = record("other-example", "oz", yesterday.replace(hour=23), 2, 3)
    output, _ = greeting()
    expected = f"Here is one of oz's: {yesterday.date().isoformat()} · fixture planning · 20m · 2 commits · 2 decisions · 3 open items"
    check("newest other-author record supplies the example with accurate counts", expected in output)
    own_record = record("own-example", "cem", yesterday.replace(hour=10), 1, 2)
    write_settings()
    noticed = subprocess.run(["bash", str(project / "bin/records.sh"), "noticed"], cwd=project,
                             env=base_env, capture_output=True, text=True, timeout=10)
    check("records noticed persists the answered offer",
          noticed.returncode == 0 and json.loads(state_path.read_text()).get("session_records_noticed") is True)
    state = json.loads(state_path.read_text())
    output = codex_card()
    check("noticed Codex card replaces the offer with the shared steady-state digest",
          "  ◦ records · yesterday 2 (1 yours) · 2 decided · 3 open · /records digest" in output
          and "Session records are" not in output and "past sessions of yours" not in output)
    output, _ = greeting()
    check("answered offer becomes the shared recent-record digest without an open-item preview",
          "  ◦ records · yesterday 2 (1 yours) · 2 decided · 3 open · /records digest" in output
          and "    - Decision 0 — oz" in output and "    - open:" not in output
          and "Session records are" not in output and "past sessions of yours" not in output)
    other_record = record("other-example", "oz", yesterday, 2, 1,
                          open_lines=["Colleague check — oz"])
    own_record.unlink()
    own_record = record("own-example", "Cem", now, 4, 4, open_lines=[
        "Coordinate handover — cem", "Review draft", "Additional own check — Cem", "Extra unowned"])
    old_record = record("old-example", "cem", now - dt.timedelta(days=2), 9, 9)
    future_record = record("future-example", "cem", now + dt.timedelta(days=1), 9, 9)
    output, _ = greeting()
    preview_lines = [line for line in output.splitlines() if line.startswith("    - ")]
    check("steady-state caps three decisions and previews no open item",
          "  ◦ records · yesterday 2 (1 yours) · 4 decided · 5 open · /records digest" in output
          and len(preview_lines) == 3
          and "    - Decision 2 — Cem" in output and "    - Decision 3" not in output
          and "    - open:" not in output and "Coordinate handover" not in output
          and "Colleague check" not in output and "Additional own check" not in output)
    own_record.write_text(own_record.read_text().replace("Decision 2", "Long decision " + "x" * 240))
    output, _ = greeting()
    long_preview = next(line for line in output.splitlines() if line.startswith("    - Long decision"))
    check("decision previews keep attribution within 120 characters",
          len(long_preview) <= 120 and "…" in long_preview and long_preview.endswith(" — Cem"))
    (trails / "index.json").write_text(json.dumps({"waiting_push": True}))
    output, _ = greeting()
    check("steady-state digest keeps the waiting-push notice",
          "◦ records ·" in output and "  ◦ 1 records commit is waiting to push · /records status --push" in output)
    other_record.unlink()
    own_record.unlink()
    output, _ = greeting()
    check("steady-state block is omitted outside the window while waiting-push remains",
          "◦ records ·" not in output and "    - " not in output
          and "1 records commit is waiting to push" in output)
    old_record.unlink()
    future_record.unlink()
    (trails / "index.json").unlink()
    config["features"]["session_records"]["enabled"] = False
    state.pop("session_records_noticed")
    output, _ = greeting()
    check("organization policy off omits every feature line", "Session records" not in output and "◦ records" not in output)
    config["features"]["session_records"]["enabled"] = True
    state["session_records_enabled"] = False
    output, _ = greeting()
    check("personal off replaces the body with the exact off notice",
          "  Your session records are off. /records on turns them back on." in output
          and "Each session now" not in output and "past sessions of yours" not in output)
    state.pop("session_records_enabled")
    config["features"]["session_records"]["model"] = "none"
    output, _ = greeting()
    check("model none omits the account sentence and keeps local trail disclosure",
          "Claude account" not in output and "The full trail stays on this\n  machine." in output)
    config["features"]["session_records"]["model"] = "haiku"
    state["session_records_model_call"] = False
    output, _ = greeting()
    check("personal model opt-out also omits the account sentence", "Claude account" not in output)
    state.pop("session_records_model_call")
    (trails / "index.json").write_text(json.dumps({"unrecorded_count": 3, "days": 3, "waiting_push": True}))
    output, _ = greeting()
    check("waiting-push cache supplies the exact retry line",
          "  ◦ 1 records commit is waiting to push · /records status --push" in output)
    if shutil.which("zsh"):
        output, _ = greeting("zsh")
        check("records block also renders in Zsh", "3 past sessions of yours" in output)
    boundary_record = record("physical-record", "oz", now, 1, 1)
    leaf_record = record("leaf-private-record", "outside-person", now + dt.timedelta(minutes=1), 1, 1)
    leaf_record.write_text(leaf_record.read_text().replace("fixture planning", "PRIVATE_LEAF_TOPIC")
                           .replace("Decision 0", "PRIVATE_LEAF_DECISION"))
    leaf_target = fixture / "leaf-target.md"
    leaf_record.rename(leaf_target)
    leaf_record.symlink_to(leaf_target)
    for noticed_state in (False, True):
        state["session_records_noticed"] = noticed_state
        output, _ = greeting()
        check(f"P3: physical record accepted and leaf symlink rejected (noticed={noticed_state})",
              "PRIVATE_LEAF" not in output and "outside-person" not in output
              and ("yesterday 1 (0 yours)" in output if noticed_state else "Here is one of oz's" in output))
        sessions = memory / "sessions"
        for relocated in (fixture / "outside-sessions", memory / "relocated-sessions"):
            sessions.rename(relocated)
            sessions.symlink_to(relocated, target_is_directory=True)
            try:
                output, _ = greeting()
                check(f"P3: sessions-root symlink rejected ({relocated.name}, noticed={noticed_state})",
                      "◦ records ·" not in output and "Here is one of" not in output
                      and "PRIVATE_LEAF" not in output)
            finally:
                sessions.unlink()
                relocated.rename(sessions)
    boundary_record.unlink()
    leaf_record.unlink()
    leaf_target.unlink()
    held_record = boundary_record.with_name(now.strftime("%d") + "-oz-held-synthetic.md")
    held_record.write_text(f'''---
kind: session-record
from: "oz"
date: "{now.date().isoformat()}"
session: "synthetic-held-session"
detail: stub
status: final
record_revision: 1
cost_usd: 0.25
cost_source: ledger
duration: "3m"
---

# Session: held

## Summary

held session · 3m · $0.25
''')
    state["session_records_noticed"] = False
    output, _ = greeting()
    check("P2: held example reads duration from minimal frontmatter",
          f"Here is one of oz's: {now.date().isoformat()} · held · 3m" in output)
    held_record.unlink()
    state["session_records_noticed"] = True
    # The reflex line replaces the open-item preview, on every startup card.
    # Only the open-items probe runs here, so other probes cannot change the card.
    shutil.copy2(repo / "bin/reflexes.sh", project / "bin/reflexes.sh")
    shutil.copy2(repo / "bin/lib/reflexes.py", project / "bin/lib/reflexes.py")
    (project / "bin/reflexes").mkdir()
    shutil.copy2(repo / "bin/reflexes/10-open-items.sh", project / "bin/reflexes/10-open-items.sh")
    for entry in ("pi-session-start.sh", "prime-session-start.sh"):
        shutil.copy2(repo / "bin" / entry, project / "bin" / entry)
    config.update(org_id="org-fixture", slug="fixture", memory_repo="https://github.com/Fixture/Fixture-Memory")
    state.update(actor_id="actor-fixture", account_id="account-fixture", membership_id="membership-fixture")
    native_path = memory / "sessions" / now.strftime("%Y-%m") / "spirit-test.md"
    native_path.write_text(f'''---
kind: "session-record"
from: "principal:fixture-spirit"
date: "{now.date().isoformat()}"
producer: "pi-durable.metadata/v1"
subject_kind: "durable-intent"
session: "spirit-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
producer_principal_id: "principal:fixture-spirit"
producer_identity: "fixture"
record_owner_actor_id: "actor-fixture"
requester_actor_id: "actor-fixture"
record_revision: 1
source_revision: 1
source_snapshot_digest: "{'a' * 64}"
observed_event_count: 0
through: null
detail: "metadata"
---
# Session: PRIVATE spirit prose
## Open
- PRIVATE forged human task
''')
    output, _ = greeting(audit=True)
    expected_spirit = "spirit records · 1 intent (1 yours) · partial coverage"
    check("Claude shared greeting separates authorized native metadata without transcripts",
          expected_spirit in output and "PRIVATE" not in output and "◦ records · yesterday" not in output)
    for entry in ("codex-session-start.sh", "pi-session-start.sh", "prime-session-start.sh"):
        output = codex_card(entry)
        check(entry + " separates native intent from human session", expected_spirit in output
              and "PRIVATE" not in output and "◦ records · yesterday" not in output)
    native_path.write_text(native_path.read_text().replace('producer: "pi-durable.metadata/v1"', 'producer: ""'))
    output, _ = greeting()
    check("malformed producer is unsupported rather than human", "1 unsupported spirit records" in output
          and "PRIVATE" not in output and "◦ records · yesterday" not in output)
    native_path.unlink()
    probe_records = [record("probe-today", "cem", now, 1, 0, open_lines=["Write the fixture summary — cem"]),
                     record("probe-stale", "oz", now - dt.timedelta(days=4), 0, 0,
                            open_lines=["Settle the fixture retention — unstated owner"])]
    output, _ = greeting()
    lines = output.splitlines()
    probe = '  ◦ 2 open items carried (oldest 4d: "Settle the fixture retention") · 1 yours · /records open --mine'
    records_line = next((index for index, line in enumerate(lines)
                         if line.startswith("  ◦ records · yesterday 1 (1 yours) · 1 decided · 1 open")), None)
    check("the reflex line carries open items under the records block",
          records_line is not None and probe in lines and lines.index(probe) > records_line
          and "    - open:" not in output and "/records file" not in output)
    probe_records.append(record("probe-first", "oz", now - dt.timedelta(days=8), 0, 0,
                                open_lines=["Settle the fixture retention"]))
    retention = hashlib.sha256(b"settle the fixture retention").hexdigest()[:6]
    proposal = '  ◦ 2 open items carried (oldest 8d: "Settle the fixture retention") · 1 yours · /records open --mine'
    output, _ = greeting()
    check("past seven days the reflex line does not demand an owner or filing", proposal in output.splitlines())
    check("Codex card prints the same reflex line", proposal in codex_card().splitlines())
    check("Pi card prints the same reflex line", proposal in codex_card("pi-session-start.sh").splitlines())
    check("Prime card prints the same reflex line", proposal in codex_card("prime-session-start.sh").splitlines())
    for path in probe_records:
        path.unlink()
    # The budget below is the records block's. The runner keeps its own budget
    # (tests/test-reflexes.sh) and the probe its own (tests/test-records-open-items.sh).
    (project / "bin/reflexes.sh").unlink()
    record("latency-own", "cem", now, 4, 4)
    record("latency-other", "oz", yesterday, 3, 2)
    output, _ = greeting()
    check("latency fixture renders the steady-state digest", "· /records digest" in output)
    off_times, on_times = [], []
    for _ in range(3):
        config["features"]["session_records"]["enabled"] = False
        off_times.append(greeting()[1])
        config["features"]["session_records"]["enabled"] = True
        on_times.append(greeting()[1])
    added_ms = (statistics.median(on_times) - statistics.median(off_times)) * 1000
    check(f"feature median overhead stays within 150 ms ({budget.note(added_ms, 150)})", added_ms <= budget.limit(150))
    print(f"{count} passed, 0 failed")
except Exception as exc:
    print(f"FAIL: {exc}", file=sys.stderr)
    print(f"{count} passed, 1 failed")
    raise SystemExit(1)
finally:
    Path(f"/tmp/egregore-subagent-ctx-greeting-records-{os.getpid()}.txt").unlink(missing_ok=True)
PY
