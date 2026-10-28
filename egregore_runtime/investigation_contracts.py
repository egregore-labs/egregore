"""Typed requests shared by native context compilation and investigation tools.

The compatibility projection preserves existing Observe query settings and source
packaging. It is constructed by trusted adapters, never from model authority fields.
"""
from __future__ import annotations

from dataclasses import dataclass, field
import json
from typing import Any, Mapping

from .contracts import RetrievalRequest


@dataclass(frozen=True)
class ContextProjection:
    retrieval: RetrievalRequest
    token_budget: int
    minimum_evidence: int = 1
    recent_days: int | None = None


@dataclass(frozen=True)
class InvestigationRequest:
    operation: str
    parameters: Mapping[str, Any] = field(default_factory=dict)
    context: ContextProjection | None = None

    def to_dict(self) -> dict:
        result = {"operation": self.operation, **self.parameters}
        if self.context:
            result["context_projection"] = {
                "retrieval": self.context.retrieval.to_dict(),
                "token_budget": self.context.token_budget,
                "minimum_evidence": self.context.minimum_evidence,
                "recent_days": self.context.recent_days,
            }
        return result

    @classmethod
    def discover_context(cls, retrieval, *, token_budget, gap="", minimum_evidence=1, recent_days=None):
        if not isinstance(retrieval, RetrievalRequest):
            raise ValueError("context discovery requires a typed RetrievalRequest")
        if type(token_budget) is not int or token_budget < 1:
            raise ValueError("context token budget must be positive")
        if type(minimum_evidence) is not int or minimum_evidence < 1:
            raise ValueError("minimum evidence must be positive")
        if recent_days is not None and (type(recent_days) is not int or not 1 <= recent_days <= 36500):
            raise ValueError("recent_days must be between 1 and 36500")
        return cls("discover", {"gap": gap}, ContextProjection(
            retrieval, token_budget, minimum_evidence, recent_days))

    @classmethod
    def parse(cls, value):
        if isinstance(value, cls):
            return value
        if not isinstance(value, dict):
            raise ValueError("investigation request must be an object")
        operation = value.get("operation")
        allowed = {
            "discover": {"kind", "query", "gap", "cursor", "after", "before", "recent_days",
                         "timezone", "prefix", "artifact_type", "limit"},
            "open": {"path", "offset", "length"},
            "open_many": {"paths", "offset", "length"},
            "status": set(),
        }
        if operation not in allowed:
            raise ValueError("operation must be discover, open, open_many, or status")
        unknown = set(value) - allowed[operation] - {"operation"}
        if unknown:
            raise ValueError("unsupported request fields: " + ", ".join(sorted(unknown)))
        parameters = {key: item for key, item in value.items() if key != "operation"}
        for key in ("kind", "query", "gap", "cursor", "after", "before", "timezone", "prefix", "artifact_type", "path"):
            if key in parameters and not isinstance(parameters[key], str):
                raise ValueError(f"{key} must be a string")
        for key in ("limit", "recent_days", "offset", "length"):
            if key in parameters and type(parameters[key]) is not int:
                raise ValueError(f"{key} must be an integer")
        if operation == 'open_many':
            paths = parameters.get('paths')
            if not isinstance(paths, list) or not 1 <= len(paths) <= 10 or any(
                not isinstance(path, str) or not path.startswith('memory/') for path in paths
            ):
                raise ValueError('open_many requires 1–10 canonical memory paths')
        return cls(operation, parameters)


def decode_request(raw: str) -> dict:
    if len(raw.encode("utf-8")) > 32768:
        raise ValueError("investigation request exceeds 32768 bytes")

    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"duplicate request field: {key}")
            result[key] = value
        return result

    value = json.loads(raw, object_pairs_hook=unique,
                       parse_constant=lambda _: (_ for _ in ()).throw(ValueError("non-finite JSON value")))
    if not isinstance(value, dict):
        raise ValueError("investigation request must be a JSON object")
    return value
