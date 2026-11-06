"""Opt-in, authorized issue advice with an explicit external processing boundary."""

from __future__ import annotations

from datetime import UTC, datetime
import hashlib
import json
import os
from pathlib import Path

from .contracts import Permission
from .issue_reporting import AREAS, KINDS, SEVERITIES
from .issue_triage import DEFAULT_MODEL, QUESTION_SET_VERSION, prepare_report, triage_report
from .policy import allows, action_for


RESOURCE = "provider:typesafe:issue-triage"


def triage_credential(root):
    """Read only the named credential; never source a shell environment file."""
    key = os.environ.get("TYPESAFE_API_KEY", "").strip()
    if key:
        return key
    path = Path(root) / ".env"
    if path.is_file():
        for line in path.read_text(encoding="utf-8").splitlines():
            if line.startswith("TYPESAFE_API_KEY="):
                return line.split("=", 1)[1].strip().strip("\"'")
    return ""


class IssueTriage:
    def __init__(self, root, runtime, actor, *, advisor=triage_report, credential_loader=triage_credential):
        self.root, self.runtime, self.actor = Path(root), runtime, actor
        self.advisor, self.credential_loader = advisor, credential_loader

    def _authorize(self, permission):
        decision = self.runtime.authorize(self.actor, permission, (RESOURCE,))
        if not decision.allowed or not allows(decision, "memory/knowledge/issues/", action_for(decision.permission), root=self.runtime.canonical_root):
            raise PermissionError("issue triage is outside the actor's authorized scope")

    def run(self, title, description, *, environment=None, evidence=None,
            kind=None, area=None, severity=None, preview=False):
        for permission in (Permission.DISCOVER, Permission.READ):
            self._authorize(permission)
        explicit = {"kind": kind, "area": area, "severity": severity}
        for name, allowed in (("kind", KINDS), ("area", AREAS), ("severity", SEVERITIES)):
            if explicit[name] is not None and explicit[name] not in allowed:
                raise ValueError(f"invalid confirmed {name}")
        report = prepare_report(title, description, environment=environment, evidence=evidence)
        config = json.loads((self.root / "egregore.json").read_text(encoding="utf-8"))
        issues = config.get("issues") or {}
        settings = (issues.get("triage") or {}) if isinstance(issues, dict) else {}
        if not isinstance(settings, dict):
            raise ValueError("issues.triage must be an object")
        enabled = settings.get("enabled") is True
        model = settings.get("model", DEFAULT_MODEL)
        included = ["title", "description"]
        if environment:
            included.append("explicitly supplied environment")
        if evidence:
            included.append("explicitly supplied evidence")
        disclosure = {
            "recipient": "TypeSafe AI",
            "endpoint": "https://api.typesafe.ai/v1/systemone",
            "included": included,
            "data_handling": "https://docs.typesafe.ai/legal",
            "notice": "When triage runs, TypeSafe AI processes the selected report text. No transcripts or additional memory are collected.",
        }
        result = {
            "schema_version": "egregore-issue-triage/v1",
            "provider": "typesafe",
            "model": model,
            "question_set_version": QUESTION_SET_VERSION,
            "created_at": datetime.now(UTC).isoformat(),
            "input_digest": hashlib.sha256(json.dumps(report, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode("utf-8")).hexdigest(),
            "status": "preview" if preview else "disabled",
            "answers": {},
            "suggestions": {"kind": None, "area": None, "severity": None},
            "missing_fields": [],
            "review_required": True,
        }
        if preview:
            result["notice"] = "Preview only. No report text sent and no issue changed."
        elif not enabled:
            result["notice"] = "Triage is off. Review the TypeSafe processing disclosure before enabling issues.triage. Filing remains available."
        elif settings.get("provider", "typesafe") != "typesafe":
            result.update(status="unavailable", reason="unsupported_provider")
        else:
            self._authorize(Permission.SHARE)
            # Permission and scope checks precede credential access and all
            # provider traffic. Enabling this adapter is separate from choosing
            # the GitHub/support destination of a report.
            try:
                key = self.credential_loader(self.root)
            except (OSError, UnicodeError):
                key = ""
            result = self.advisor(report, api_key=key, model=model)
        suggestions = result.get("suggestions", {})
        if kind is not None and kind != "bug":
            # User-confirmed kind controls relevance even when the model's
            # kind answer disagrees. Keep raw answers for evaluation.
            suggestions = {**suggestions, "severity": None}
            result["suggestions"] = suggestions
            result["missing_fields"] = []
        result["confirmed_fields"] = {name: value for name, value in explicit.items() if value is not None}
        result["draft_fields"] = {
            "kind": kind or suggestions.get("kind") or "bug",
            "area": area or suggestions.get("area") or "other",
            # An impact recommendation never silently becomes confirmed severity.
            "severity": severity or "normal",
        }
        result["draft_field_sources"] = {
            name: "human" if explicit[name] is not None else (
                "advisor" if name != "severity" and suggestions.get(name) is not None else "default"
            )
            for name in ("kind", "area", "severity")
        }
        result["enabled"] = enabled
        result["disclosure"] = disclosure
        result["selected_report"] = report
        result["issue_changed"] = False
        return result
