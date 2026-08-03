#!/usr/bin/env python3
"""Reconcile one Egregore member identity into state and memory/people."""

from __future__ import annotations

import argparse
import json
import os
import re
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


ROOT = Path(
    os.environ.get("EGREGORE_PERSON_ROOT")
    or Path(__file__).resolve().parent.parent
).resolve()
STATE_PATH = ROOT / ".egregore-state.json"
PEOPLE_DIR = ROOT / "memory" / "people"
FIELD_ORDER = (
    "Person-ID",
    "GitHub",
    "GitHub-ID",
    "GitHub-Aliases",
    "Email",
    "Emails",
    "Previous-Names",
    "Role",
    "Joined",
    "Onboarded",
)


def clean_strings(values: list[Any], *, lower: bool = False) -> list[str]:
    result: list[str] = []
    seen: set[str] = set()
    for value in values:
        if not isinstance(value, str) or not value.strip():
            continue
        item = value.strip().lower() if lower else value.strip()
        key = item.lower()
        if key not in seen:
            seen.add(key)
            result.append(item)
    return result


def comma_values(value: Any) -> list[str]:
    if isinstance(value, list):
        return clean_strings(value)
    if not isinstance(value, str):
        return []
    return clean_strings([item for item in value.split(",")])


def parse_profile(path: Path) -> dict[str, Any]:
    text = path.read_text(encoding="utf-8") if path.exists() else ""
    yaml_fields: dict[str, str] = {}
    if text.startswith("---\n"):
        parts = text.split("\n---\n", 1)
        if len(parts) == 2:
            for line in parts[0].splitlines()[1:]:
                if ":" in line:
                    key, value = line.split(":", 1)
                    yaml_fields[key.strip().lower()] = value.strip().strip("\"'")
            text = parts[1]
    lines = text.splitlines()
    title = yaml_fields.get("display_name") or yaml_fields.get("name") or ""
    fields: dict[str, str] = {}
    yaml_map = {
        "person_id": "Person-ID",
        "github": "GitHub",
        "github_id": "GitHub-ID",
        "email": "Email",
        "role": "Role",
        "joined": "Joined",
        "onboarded": "Onboarded",
    }
    for source, target in yaml_map.items():
        if yaml_fields.get(source):
            fields[target] = yaml_fields[source]
    body: list[str] = []
    for line in lines:
        if not title and line.startswith("# "):
            title = line[2:].strip()
            continue
        matched = False
        for field in FIELD_ORDER:
            if line.lower().startswith(field.lower() + ":"):
                fields[field] = line.split(":", 1)[1].strip()
                matched = True
                break
        if not matched:
            body.append(line)
    while body and not body[0].strip():
        body.pop(0)
    return {"title": title, "fields": fields, "body": "\n".join(body).strip()}


def display_slug(value: str) -> str:
    return re.sub(r"-+", "-", re.sub(r"[^a-z0-9]+", "-", value.lower())).strip("-")


def atomic_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.replace(temp_name, path)
    finally:
        if os.path.exists(temp_name):
            os.unlink(temp_name)


def atomic_json(path: Path, value: dict[str, Any]) -> None:
    atomic_text(path, json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def alias_candidate(
    path: Path,
    profile: dict[str, Any],
    *,
    canonical: Path,
    person_id: str,
    github: str,
    github_aliases: list[str],
    preferred_slug: str,
) -> bool:
    if path == canonical or path.name == "index.md":
        return False
    fields = profile["fields"]
    profile_pid = fields.get("Person-ID", "")
    profile_github = fields.get("GitHub", "").lower()
    stem = path.stem.lower()
    if profile_pid and profile_pid == person_id:
        return True
    if profile_github and profile_github == github.lower():
        return True
    if stem in {item.lower() for item in github_aliases}:
        return True
    # Back-compat duplicate created before identity metadata existed. Restrict
    # this heuristic to tiny witness files so a real teammate profile is never
    # absorbed merely because two people prefer the same name.
    if (
        stem == preferred_slug
        and not profile_github
        and len(path.read_text(encoding="utf-8").splitlines()) <= 12
    ):
        return True
    return False


def choose_source_profile(
    *,
    github: str,
    display_name: str,
    github_name: str,
) -> tuple[Path | None, list[str]]:
    """Choose one legacy profile conservatively.

    Exact GitHub-addressed profiles win. Preferred/display-name matching is
    accepted only when it identifies one file, so two people called "Kaan"
    can never be merged by a bulk run.
    """
    profiles = [
        path for path in sorted(PEOPLE_DIR.glob("*.md"))
        if path.name != "index.md"
    ]
    canonical = PEOPLE_DIR / f"{github}.md"
    if canonical.exists():
        return canonical, []

    github_matches = [
        path for path in profiles
        if parse_profile(path)["fields"].get("GitHub", "").lower() == github.lower()
    ]
    if len(github_matches) == 1:
        return github_matches[0], []

    preferred_slug = display_slug(display_name)
    slug_matches = [
        path for path in profiles
        if preferred_slug and path.stem.lower() == preferred_slug
    ]
    if len(slug_matches) == 1:
        return slug_matches[0], []

    names = {
        value.strip().lower()
        for value in (display_name, github_name)
        if value and value.strip()
    }
    title_matches = [
        path for path in profiles
        if parse_profile(path)["title"].strip().lower() in names
    ]
    if len(title_matches) == 1:
        return title_matches[0], []

    ambiguous = sorted({
        path.name
        for matches in (github_matches, slug_matches, title_matches)
        if len(matches) > 1
        for path in matches
    })
    return None, ambiguous


def render_identity_profile(
    *,
    canonical: Path,
    source: Path | None,
    person_id: str,
    github: str,
    github_id: int | None,
    github_name: str,
    display_name: str,
    emails: list[str],
    github_aliases: list[str],
    previous_names: list[str],
    role: str,
    joined: str,
    onboarded: str,
    dry_run: bool,
) -> dict[str, Any]:
    """Render one canonical profile and safe alias witnesses."""
    canonical_existed = canonical.exists()
    current = parse_profile(canonical)
    source_profile = (
        parse_profile(source)
        if source is not None and source != canonical
        else {"title": "", "fields": {}, "body": ""}
    )
    source_fields = source_profile["fields"]
    current_fields = current["fields"]

    emails = clean_strings(
        emails
        + comma_values(current_fields.get("Emails"))
        + [current_fields.get("Email")]
        + comma_values(source_fields.get("Emails"))
        + [source_fields.get("Email")],
        lower=True,
    )
    github_aliases = clean_strings(
        github_aliases
        + comma_values(current_fields.get("GitHub-Aliases"))
        + comma_values(source_fields.get("GitHub-Aliases")),
        lower=True,
    )
    previous_names = clean_strings(
        previous_names
        + comma_values(current_fields.get("Previous-Names"))
        + comma_values(source_fields.get("Previous-Names"))
    )

    alias_paths: list[Path] = []
    merged_bodies: list[str] = []
    preferred_slug = display_slug(display_name)
    for path in sorted(PEOPLE_DIR.glob("*.md")):
        profile = parse_profile(path)
        explicitly_selected = source is not None and path == source and path != canonical
        if not explicitly_selected and not alias_candidate(
            path,
            profile,
            canonical=canonical,
            person_id=person_id,
            github=github,
            github_aliases=github_aliases,
            preferred_slug=preferred_slug,
        ):
            continue
        alias_paths.append(path)
        if profile["body"] and "This identity is represented by" not in profile["body"]:
            merged_bodies.append(profile["body"])
        alias_github = profile["fields"].get("GitHub", "")
        if alias_github and alias_github.lower() != github.lower():
            github_aliases = clean_strings(github_aliases + [alias_github], lower=True)
        if (
            profile["title"]
            and profile["title"].lower() != display_name.lower()
        ):
            previous_names = clean_strings(previous_names + [profile["title"]])

    for title in (current["title"], source_profile["title"]):
        if title and title.lower() != display_name.lower():
            previous_names = clean_strings(previous_names + [title])

    metadata = {
        "Person-ID": person_id,
        "GitHub": github,
        "GitHub-ID": str(github_id or ""),
        "GitHub-Aliases": ", ".join(github_aliases),
        "Email": emails[0] if emails else "",
        "Emails": ", ".join(emails),
        "Previous-Names": ", ".join(previous_names),
        "Role": (
            current_fields.get("Role")
            or source_fields.get("Role")
            or role
            or "Member"
        ),
        "Joined": (
            current_fields.get("Joined")
            or source_fields.get("Joined")
            or joined
            or datetime.now(timezone.utc).date().isoformat()
        ),
        "Onboarded": (
            current_fields.get("Onboarded")
            or source_fields.get("Onboarded")
            or onboarded
        ),
    }
    bodies = clean_strings([
        current["body"],
        source_profile["body"],
        *merged_bodies,
    ])
    rendered = [f"# {display_name}", ""]
    rendered.extend(
        f"{field}: {metadata[field]}"
        for field in FIELD_ORDER
        if metadata[field] or field != "Onboarded"
    )
    if bodies:
        rendered.extend(["", "\n\n".join(bodies)])

    canonical_text = "\n".join(rendered).rstrip() + "\n"
    alias_texts: dict[Path, str] = {}
    for path in alias_paths:
        profile = parse_profile(path)
        alias_texts[path] = "\n".join(
            [
                f"# {profile['title'] or display_name}",
                "",
                f"Person-ID: {person_id}",
                f"Alias-Of: {canonical.name}",
                f"GitHub: {github}",
                "",
                f"This identity is represented by [{canonical.name}](./{canonical.name}).",
                "",
            ]
        )
    canonical_changed = (
        not canonical_existed
        or canonical.read_text(encoding="utf-8") != canonical_text
    )
    aliases_changed = any(
        not path.exists() or path.read_text(encoding="utf-8") != text
        for path, text in alias_texts.items()
    )
    profile_action = (
        "create"
        if not canonical_existed
        else "update"
        if canonical_changed or aliases_changed
        else "unchanged"
    )

    if not dry_run:
        canonical.parent.mkdir(parents=True, exist_ok=True)
        if canonical_changed:
            atomic_text(canonical, canonical_text)
        for path, alias_text in alias_texts.items():
            if not path.exists() or path.read_text(encoding="utf-8") != alias_text:
                atomic_text(path, alias_text)

    return {
        "schema": "egregore-person-identity/v1",
        "person_id": person_id,
        "github_username": github,
        "github_id": github_id,
        "github_name": github_name or display_name,
        "display_name": display_name,
        "email": emails[0] if emails else None,
        "emails": emails,
        "github_aliases": github_aliases,
        "previous_names": previous_names,
        "profile_path": f"people/{canonical.name}",
        "source_profile": source.name if source else None,
        "profile_action": profile_action,
        "aliases_reconciled": [path.name for path in alias_paths],
        "dry_run": dry_run,
    }


def reconcile_profile(args: argparse.Namespace) -> dict[str, Any]:
    """Reconcile an arbitrary org member without touching the current user state."""
    github = (args.github or "").strip()
    if not github or not re.fullmatch(r"[A-Za-z0-9-]{1,39}", github):
        raise ValueError("a valid GitHub login is required")
    github_id = int(args.github_id) if args.github_id not in (None, "") else None
    if github_id is None:
        # Self-heal: adopt the numeric id the canonical profile already
        # carries so a caller without --github-id cannot degrade a
        # github:<id> profile back to github-login form.
        profile_github_id = str(
            parse_profile(PEOPLE_DIR / f"{github}.md")["fields"].get("GitHub-ID") or ""
        ).strip()
        if profile_github_id.isdigit():
            github_id = int(profile_github_id)
    person_id = (
        f"github:{github_id}"
        if github_id is not None
        else f"github-login:{github.lower()}"
    )
    display_name = (
        args.display_name or args.github_name or github
    ).strip()
    source, ambiguous = choose_source_profile(
        github=github,
        display_name=display_name,
        github_name=args.github_name or "",
    )
    if args.source_profile:
        requested = PEOPLE_DIR / Path(args.source_profile).name
        if not requested.exists():
            raise ValueError(f"profile does not exist: {requested.name}")
        source = requested
        ambiguous = []

    aliases = clean_strings(comma_values(args.github_aliases), lower=True)
    prior_github = (args.previous_github or "").strip()
    if prior_github and prior_github.lower() != github.lower():
        aliases = clean_strings(aliases + [prior_github], lower=True)
    result = render_identity_profile(
        canonical=PEOPLE_DIR / f"{github}.md",
        source=source,
        person_id=person_id,
        github=github,
        github_id=github_id,
        github_name=(args.github_name or "").strip(),
        display_name=display_name,
        emails=clean_strings(comma_values(args.emails) + [args.email], lower=True),
        github_aliases=aliases,
        previous_names=[],
        role=(args.role or "").strip(),
        joined=(args.joined or "").strip(),
        onboarded="",
        dry_run=args.dry_run,
    )
    result["ambiguous_profiles"] = ambiguous
    return result


def reconcile(args: argparse.Namespace) -> dict[str, Any]:
    state = json.loads(STATE_PATH.read_text(encoding="utf-8"))
    previous_github = str(state.get("github_username") or "").strip()
    github = (args.github or state.get("github_username") or "").strip()
    if not github:
        raise ValueError("github_username is required")
    github_id = args.github_id or state.get("github_id")
    github_id = int(github_id) if github_id not in (None, "") else None
    if github_id is None:
        # Self-heal pre-migration state: a state file written before the
        # numeric-id migration carries github_id null and a github-login
        # person_id, which degraded github:<id> profiles back to login
        # form on every boot. Adopt the numeric id from the canonical
        # profile; state.update() below persists it durably.
        profile_github_id = str(
            parse_profile(PEOPLE_DIR / f"{github}.md")["fields"].get("GitHub-ID") or ""
        ).strip()
        if profile_github_id.isdigit():
            github_id = int(profile_github_id)
    person_id = (
        f"github:{github_id}" if github_id is not None
        else str(state.get("person_id") or f"github-login:{github.lower()}")
    )
    display_name = (
        args.display_name
        or state.get("display_name")
        or state.get("github_name")
        or github
    ).strip()
    full_name = str(state.get("github_name") or display_name).strip()
    emails = clean_strings(
        [args.email, state.get("email"), *comma_values(state.get("emails"))],
        lower=True,
    )
    github_aliases = clean_strings(
        comma_values(state.get("github_aliases")), lower=True
    )
    if previous_github and previous_github.lower() != github.lower():
        github_aliases = clean_strings(
            github_aliases + [previous_github], lower=True
        )
    previous_names = clean_strings(comma_values(state.get("previous_names")))
    canonical = PEOPLE_DIR / f"{github}.md"
    current = parse_profile(canonical)
    fields = current["fields"]
    emails = clean_strings(
        emails + comma_values(fields.get("Emails")) + [fields.get("Email")],
        lower=True,
    )
    github_aliases = clean_strings(
        github_aliases + comma_values(fields.get("GitHub-Aliases")),
        lower=True,
    )
    previous_names = clean_strings(
        previous_names + comma_values(fields.get("Previous-Names"))
    )
    if current["title"] and current["title"].lower() != display_name.lower():
        previous_names = clean_strings(previous_names + [current["title"]])

    aliases_reconciled: list[str] = []
    merged_bodies: list[str] = []
    PEOPLE_DIR.mkdir(parents=True, exist_ok=True)
    for path in sorted(PEOPLE_DIR.glob("*.md")):
        profile = parse_profile(path)
        if not alias_candidate(
            path,
            profile,
            canonical=canonical,
            person_id=person_id,
            github=github,
            github_aliases=github_aliases,
            preferred_slug=display_slug(display_name),
        ):
            continue
        aliases_reconciled.append(path.name)
        if profile["body"] and "This identity is represented by" not in profile["body"]:
            merged_bodies.append(profile["body"])
        alias_github = profile["fields"].get("GitHub", "") or path.stem
        if alias_github.lower() != github.lower():
            github_aliases = clean_strings(github_aliases + [alias_github], lower=True)
        if profile["title"] and profile["title"].lower() != display_name.lower():
            previous_names = clean_strings(previous_names + [profile["title"]])
        alias_text = "\n".join(
            [
                f"# {profile['title'] or display_name}",
                "",
                f"Person-ID: {person_id}",
                f"Alias-Of: {canonical.name}",
                f"GitHub: {github}",
                "",
                f"This identity is represented by [{canonical.name}](./{canonical.name}).",
                "",
            ]
        )
        atomic_text(path, alias_text)

    role = state.get("member_role") or fields.get("Role") or "Member"
    now = datetime.now(timezone.utc)
    joined = fields.get("Joined") or now.date().isoformat()
    onboarded = fields.get("Onboarded") or (now.isoformat() if args.onboarded else "")
    metadata = {
        "Person-ID": person_id,
        "GitHub": github,
        "GitHub-ID": str(github_id or ""),
        "GitHub-Aliases": ", ".join(github_aliases),
        "Email": emails[0] if emails else "",
        "Emails": ", ".join(emails),
        "Previous-Names": ", ".join(previous_names),
        "Role": str(role),
        "Joined": joined,
        "Onboarded": onboarded,
    }
    rendered = [f"# {display_name}", ""]
    rendered.extend(
        f"{field}: {metadata[field]}"
        for field in FIELD_ORDER
        if metadata[field] or field not in {"Onboarded"}
    )
    bodies = clean_strings([current["body"], *merged_bodies])
    if bodies:
        rendered.extend(["", "\n\n".join(bodies)])
    atomic_text(canonical, "\n".join(rendered).rstrip() + "\n")

    state.update(
        {
            "person_id": person_id,
            "github_username": github,
            "github_id": github_id,
            "display_name": display_name,
            "email": emails[0] if emails else None,
            "emails": emails,
            "github_aliases": github_aliases,
            "previous_names": previous_names,
            "identity_version": 1,
        }
    )
    atomic_json(STATE_PATH, state)
    return {
        "schema": "egregore-person-identity/v1",
        "person_id": person_id,
        "github_username": github,
        "github_id": github_id,
        "github_name": full_name,
        "display_name": display_name,
        "email": emails[0] if emails else None,
        "emails": emails,
        "github_aliases": github_aliases,
        "previous_names": previous_names,
        "profile_path": f"people/{canonical.name}",
        "aliases_reconciled": aliases_reconciled,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("sync-local", "sync-profile"))
    parser.add_argument("--github")
    parser.add_argument("--github-id", type=int)
    parser.add_argument("--github-name")
    parser.add_argument("--github-aliases")
    parser.add_argument("--previous-github")
    parser.add_argument("--display-name")
    parser.add_argument("--email")
    parser.add_argument("--emails")
    parser.add_argument("--role")
    parser.add_argument("--joined")
    parser.add_argument("--source-profile")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--onboarded", action="store_true")
    args = parser.parse_args()
    try:
        result = reconcile_profile(args) if args.command == "sync-profile" else reconcile(args)
        print(json.dumps(result, ensure_ascii=False))
        return 0
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(json.dumps({"status": "error", "error": str(exc)}))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
