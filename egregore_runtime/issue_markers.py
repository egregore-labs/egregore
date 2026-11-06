"""Versioned issue wire markers shared by the CLI and hosted Archive feed."""
import re
from uuid import UUID

_UUID = r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
_OBSERVATION = re.compile(rf"^<!-- egregore-observation:v1 request=({_UUID}) -->$", re.MULTILINE)
_REQUEST = re.compile(rf"^<!-- egregore-issue:v1 request=({_UUID}) -->$", re.MULTILINE)
_ARTIFACT = re.compile(r"https://egregore\.xyz/view/[A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+)*")


def request_id(value):
    value = str(value)
    if str(UUID(value)) != value:
        raise ValueError("request ID must be a canonical UUID")
    return value


def observation_id(body):
    """Exactly one full-line marker; ordinary text and ambiguous markers fail closed."""
    return _recognize(_OBSERVATION, body)


def issue_request_id(body):
    return _recognize(_REQUEST, body)


def _recognize(pattern, body):
    if not isinstance(body, str):
        return None
    matches = pattern.findall(body)
    return matches[0] if len(matches) == 1 else None


def artifact_url(value):
    if not isinstance(value, str) or not _ARTIFACT.fullmatch(value):
        raise ValueError("artifact must be a published https://egregore.xyz/view/ URL without query or fragment")
    return value


def explicit_artifact(body):
    """Only the explicit structured field is eligible; never arbitrary body links."""
    if not isinstance(body, str):
        return None
    matches = re.findall(r"^Egregore artifact: (.+)$", body, re.MULTILINE)
    if len(matches) != 1:
        return None
    try:
        return artifact_url(matches[0])
    except ValueError:
        return None
