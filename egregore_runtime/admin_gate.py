"""Egregore-surface admin-content protection.

``admin: true`` frontmatter gives a canonical document its documented
meaning: hidden on Egregore surfaces from non-admin members, and refused for
external publication without an authorized admin's separate confirmation.

This is soft product-layer protection. Every organization member holds full
repository access and can read raw Git files; nothing here claims per-document
filesystem confidentiality, and no surface may describe it as an ACL. What it
guarantees is that Egregore itself — retrieval evidence, Observe context,
source opening, listings, rendering, publication — never hands admin-marked
content to a non-admin member, exposing at most an opaque withheld count.

Admin capability derives from stable identity: the resolved actor's
``github.username`` alias (recorded by onboarding into the identity state)
matched against the organization's configured ``admins`` list. Display names,
the ``legacy.person`` alias, Git configuration, OS usernames, branch names,
and paths never participate. Every error path fails closed to non-admin.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

_FRONTMATTER_ADMIN = re.compile(r"^\s*admin:\s*[\"']?true[\"']?\s*$", re.MULTILINE)
_HEAD_BYTES = 4096


def document_is_admin(text: str) -> bool:
    """True when the document's YAML frontmatter declares ``admin: true``."""

    if not text.startswith("---"):
        return False
    end = text.find("\n---", 3)
    head = text[3:end] if end != -1 else text[3:_HEAD_BYTES]
    return bool(_FRONTMATTER_ADMIN.search(head))


@dataclass
class AdminGate:
    config_path: Path
    memory_root: Path
    _flag_cache: dict[str, tuple[int, int, bool]] = field(default_factory=dict)

    def admin_handles(self) -> frozenset[str]:
        try:
            config: Any = json.loads(self.config_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return frozenset()
        handles = config.get("admins") if isinstance(config, dict) else None
        if not isinstance(handles, list):
            return frozenset()
        return frozenset(
            str(handle).strip().casefold()
            for handle in handles
            if str(handle).strip()
        )

    def actor_is_admin(self, actor: Any) -> bool:
        """Stable-identity admin check — github.username alias only."""

        handles = self.admin_handles()
        if not handles:
            return False
        try:
            aliases = getattr(actor.actor, "aliases", None) or {}
            handle = aliases.get("github.username") if isinstance(aliases, dict) else None
        except AttributeError:
            return False
        if not handle:
            return False
        return str(handle).strip().casefold() in handles

    def path_is_admin(self, canonical_path: str) -> bool:
        """True when the canonical document at ``memory/...`` is admin-marked.

        Unreadable or missing files report False — absence of evidence is not
        an admin marking, and the surrounding authorization already decided
        whether the path may be read at all.
        """

        relative = canonical_path.strip().replace("\\", "/").removeprefix("memory/")
        target = self.memory_root / relative
        try:
            stat = target.stat()
        except OSError:
            return False
        cached = self._flag_cache.get(relative)
        if cached and cached[0] == stat.st_mtime_ns and cached[1] == stat.st_size:
            return cached[2]
        try:
            with target.open("r", encoding="utf-8", errors="replace") as handle:
                head = handle.read(_HEAD_BYTES)
        except OSError:
            return False
        flag = document_is_admin(head)
        self._flag_cache[relative] = (stat.st_mtime_ns, stat.st_size, flag)
        return flag
