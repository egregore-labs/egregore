"""Disposable observers for completed, authorized Runtime operations."""

from dataclasses import dataclass
from typing import Callable
from .contracts import ExecutionAuthority


@dataclass(frozen=True, slots=True)
class RuntimeEvent:
    kind: str
    actor_id: str
    session_id: str
    harness: str
    paths: tuple[str, ...]
    execution: ExecutionAuthority | None = None


Observer = Callable[[RuntimeEvent], None]
MAX_EVENT_PATHS = 40
