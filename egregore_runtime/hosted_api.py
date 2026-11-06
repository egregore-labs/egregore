"""The address every hosted request goes to.

The hosted API moved to api.egregore.xyz after the October 2026 security
reset. Its old Railway origin was retired and is no longer ours to trust: a
credential sent there could reach whoever holds that address next. Every
request that carries a token or key resolves its address here, so a
configuration or environment saved before the move never reaches it.

The rule is an allowlist, not a normalizer. Only a plain web address is used:
http or https, a host of ASCII letters, digits, dots, hyphens and underscores,
an optional port and a plain path. Every transport reads such an address the
same way, so its host is the one the request reaches. A plain address on the
retired host becomes the hosted API; any other plain address is kept.
Anything else is refused, because curl, urllib and WHATWG parsers disagree
about where it goes: userinfo, backslashes, percent-encoding, curl glob
characters, a query or fragment, whitespace or invisible characters inside,
a ``URL:`` prefix, non-ASCII. A refused address raises
:class:`RefusedApiAddress` and nothing is sent.

The shell (bin/lib/config.sh), Node (packages/create-egregore/lib/
hosted-api.js) and connector resolvers follow the same table:
bin/tests/fixtures/hosted-api-url-vectors.json.
"""

from __future__ import annotations

import re
import sys
from typing import Mapping
from urllib.request import Request

HOSTED_API_ORIGIN = "https://api.egregore.xyz"
RETIRED_API_ORIGIN = "https://egregore-production-55f2.up.railway.app"
REFUSED_API_ADDRESS_NOTICE = (
    "The hosted services address isn't a plain web address, so nothing was sent. "
    f"Correct api_url in egregore.json; the hosted address is {HOSTED_API_ORIGIN}."
)

_RETIRED_HOST = RETIRED_API_ORIGIN.split("://", 1)[1]
_WHITESPACE = " \t\n\r\f\v"
_PLAIN = re.compile(r"https?://([A-Za-z0-9._-]+)(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?")
# The start of a request URL: a plain origin, then a path, query or nothing.
_PLAIN_ORIGIN = re.compile(r"https?://([A-Za-z0-9._-]+)(:[0-9]{1,5})?(?=[/?#]|\Z)")
_notice_shown = False


class RefusedApiAddress(ValueError):
    """The hosted address is not a plain web address, so nothing may be sent to it."""

    def __init__(self) -> None:
        super().__init__(REFUSED_API_ADDRESS_NOTICE)


def _refuse() -> RefusedApiAddress:
    """Say why once per process on stderr, and return the error to raise."""
    global _notice_shown
    if not _notice_shown:
        _notice_shown = True
        try:
            print(REFUSED_API_ADDRESS_NOTICE, file=sys.stderr)
        except (OSError, ValueError):
            pass
    return RefusedApiAddress()


def _retired_host(host: str) -> bool:
    return host.lower().rstrip(".") == _RETIRED_HOST


def retired_api_url(value: object) -> bool:
    """Whether ``value`` is a plain address on the retired hosted origin."""
    text = ("" if value is None else str(value)).strip(_WHITESPACE)
    plain = _PLAIN.fullmatch(text)
    return bool(plain) and _retired_host(plain.group(1))


def hosted_api_url(value: object, exact: bool = False) -> str:
    """The address to send a request to.

    A plain address on the retired origin becomes the hosted API, keeping its
    path, with trailing slashes trimmed. Any other plain address keeps its text
    apart from surrounding whitespace and trailing slashes; empty stays empty.
    Anything else raises :class:`RefusedApiAddress`, and the caller sends
    nothing.

    ``exact`` is for the server's own settings, such as an OAuth redirect URI
    that is compared exactly: only a plain retired address changes, and every
    other value is returned byte for byte, never refused.
    """
    text = "" if value is None else str(value)
    trimmed = text.strip(_WHITESPACE)
    plain = _PLAIN.fullmatch(trimmed)
    if plain and _retired_host(plain.group(1)):
        return (HOSTED_API_ORIGIN + (plain.group(3) or "")).rstrip("/")
    if exact:
        return text
    if not trimmed:
        return ""
    if not plain:
        raise _refuse()
    return trimmed.rstrip("/")


_CREDENTIAL_HEADER = re.compile(r"authorization|cookie|token|key|secret|auth", re.IGNORECASE)


def credential_request(
    url: str,
    *,
    headers: Mapping[str, str] | None = None,
    data: bytes | None = None,
    method: str | None = None,
) -> Request:
    """A request whose credentials reach only a plain, current hosted address.

    The URL must start with a plain origin that is not the retired one;
    otherwise :class:`RefusedApiAddress` is raised and nothing is built. The
    resolver already guarantees that for an address it returned; this holds it
    for every URL built from one.

    urllib's redirect handler copies only ``Request.headers`` to the next
    request. Authorization, cookies and any token, key or secret header are
    added with ``add_unredirected_header`` instead, so they stay with the
    first request and cannot follow a redirect to another host. A redirected
    POST loses its body (urllib refuses 307 and 308 for it), so a credential
    in the body stays behind too.
    """
    origin = _PLAIN_ORIGIN.match(url) if isinstance(url, str) else None
    if not origin or _retired_host(origin.group(1)):
        raise _refuse()
    request = Request(url, data=data, method=method)
    for name, value in (headers or {}).items():
        if _CREDENTIAL_HEADER.search(name):
            request.add_unredirected_header(name, value)
        else:
            request.add_header(name, value)
    return request
