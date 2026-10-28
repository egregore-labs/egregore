"""Native prompt identity and late-result fencing, independent of retrieval.

Binding records contain identifiers only. An optional private question sidecar
retains native prompt text for excerpt selection; evidence stays in the existing
investigation store. A tool must carry its prompt's reference; this module never
chooses the newest native conversation on the caller's behalf.
"""
from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass
import fcntl
import hashlib
import json
import os
from pathlib import Path
import secrets
import time

from .errors import EgregoreRuntimeError

MAX_QUESTION_BYTES = 262144

class EpisodeBindingError(EgregoreRuntimeError):
    pass


def _directory(root):
    directory = Path(root) / ".egregore/runtime/bindings"
    if not directory.resolve().is_relative_to(Path(root).resolve()):
        raise EpisodeBindingError("episode bindings must remain inside this instance")
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(directory, 0o700)
    return directory


def _key(value):
    return hashlib.sha256(value.encode()).hexdigest()


def _load(path, *, max_bytes=8192):
    if path.is_symlink():
        raise EpisodeBindingError("invalid episode binding path")
    try:
        if path.stat().st_size > max_bytes:
            raise EpisodeBindingError("episode binding is too large")
        value = json.loads(path.read_text())
    except (OSError, ValueError) as error:
        raise EpisodeBindingError("episode binding unavailable; use the reference attached to this prompt") from error
    if not isinstance(value, dict):
        raise EpisodeBindingError("invalid episode binding")
    return value


def _save(path, value):
    temporary = path.with_suffix("." + secrets.token_hex(8) + ".tmp")
    try:
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w") as handle:
            json.dump(value, handle, separators=(",", ":"))
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


@contextmanager
def _lock(directory, key):
    path = directory / (key + ".lock")
    descriptor = os.open(path, os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0), 0o600)
    with os.fdopen(descriptor, "a") as handle:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


@dataclass(frozen=True)
class EpisodeBinding:
    episode_id: str
    session_id: str
    conversation_key: str
    org_id: str
    actor_id: str
    native_turn_id: str | None = None

    def check(self, root, actor):
        if (actor.profile.org_id, actor.actor.actor_id) != (self.org_id, self.actor_id):
            raise EpisodeBindingError("episode belongs to another actor or organization")
        current = _load(_directory(root) / (self.conversation_key + ".current"))
        if current.get("episode_id") != self.episode_id:
            raise EpisodeBindingError("episode closed by a newer prompt; discard this result")

    def question(self, root, actor):
        """Read only this authorized prompt's private text, never another turn's."""
        self.check(root, actor)
        path = _directory(root) / (_key(self.episode_id) + ".question")
        if not path.exists():
            return ""
        value = _load(path, max_bytes=MAX_QUESTION_BYTES)
        if value.get('episode_id') != self.episode_id or not isinstance(value.get('question'), str):
            raise EpisodeBindingError("invalid episode question")
        return value['question']


def begin(root, actor, *, harness, session_id, native_turn_id=None, question=""):
    """Called by a native prompt event, never exposed as a model reset command."""
    if not session_id or len(session_id) > 200:
        raise EpisodeBindingError("native session identity is required")
    if native_turn_id is not None and (not isinstance(native_turn_id, str) or len(native_turn_id) > 200):
        raise EpisodeBindingError("invalid native turn identity")
    directory = _directory(root)
    conversation = _key(f"{harness}:{session_id}")
    current_path = directory / (conversation + ".current")
    prompt_path = directory / (_key(f"{conversation}:{native_turn_id}") + ".prompt") if native_turn_id else None
    with _lock(directory, conversation):
        if prompt_path and prompt_path.exists():
            # A repeated old native event cannot reopen a closed generation.
            previous = _load(prompt_path)
            binding = resolve(root, previous["episode_id"])
            binding.check(root, actor)
            return binding
        binding = EpisodeBinding("ep_" + secrets.token_hex(16), session_id, conversation,
                                 actor.profile.org_id, actor.actor.actor_id, native_turn_id)
        value = {**binding.__dict__, "created_at": time.time()}
        question_value = {'episode_id': binding.episode_id, 'question': question}
        # Oversized pasted inputs use the search query for selection instead.
        # Keep normal questions whole, without adding text to identity records.
        if question and len(json.dumps(question_value, separators=(',', ':')).encode()) <= MAX_QUESTION_BYTES:
            _save(directory / (_key(binding.episode_id) + ".question"), question_value)
        _save(directory / (_key(binding.episode_id) + ".episode"), value)
        _save(current_path, value)
        if prompt_path:
            _save(prompt_path, value)
        return binding


def resolve(root, episode_id):
    if not isinstance(episode_id, str) or not episode_id.startswith("ep_") or len(episode_id) != 35:
        raise EpisodeBindingError("invalid episode reference")
    value = _load(_directory(root) / (_key(episode_id) + ".episode"))
    if value.get("episode_id") != episode_id:
        raise EpisodeBindingError("episode reference does not match its record")
    try:
        return EpisodeBinding(**{key: value[key] for key in EpisodeBinding.__dataclass_fields__})
    except (KeyError, TypeError) as error:
        raise EpisodeBindingError("invalid episode binding") from error


def requires_binding(root):
    directory = Path(root) / ".egregore/runtime/bindings"
    return directory.exists() and any(directory.glob("*.current"))


def context_line(binding):
    return (f"Investigation reference: {binding.episode_id}. "
            "Runtime binds commands automatically when the native session identity is available. "
            "Only if a command reports missing native binding, pass this reference with --episode. "
            "Never substitute another prompt's reference.")


def resolve_native(root, *, harness, session_id):
    """Pin the caller's native conversation at command entry, never a global latest.

    The existing delivery fence rejects a result if a newer prompt arrives
    while retrieval runs.
    """
    if not session_id or len(session_id) > 200:
        raise EpisodeBindingError('native session identity is required')
    conversation = _key(f'{harness}:{session_id}')
    path = Path(root) / '.egregore/runtime/bindings' / (conversation + '.current')
    if not path.exists():
        return None
    current = _load(path)
    binding = resolve(root, current.get('episode_id'))
    if binding.session_id != session_id or binding.conversation_key != conversation:
        raise EpisodeBindingError('native conversation binding does not match')
    return binding
