"""Held material: the classes a non-admin is never handed, decided in one place.

``admin: true`` frontmatter gives a canonical document its documented
meaning: hidden on Egregore surfaces from non-admin members, and refused for
external publication without an authorized admin's separate confirmation.

This is soft product-layer protection. Every organization member holds full
repository access and can read raw Git files; nothing here claims per-document
filesystem confidentiality, and no surface may describe it as an ACL. What it
guarantees is that Egregore itself — retrieval evidence, Observe context,
source opening, listings, rendering, publication — never hands admin-marked
content to a non-admin member, exposing at most an opaque withheld count.

Admin capability is decided by ``policy.is_admin`` from the roster that
``access.authorization_inputs`` reads; ``policy.check`` applies every class.
Every hold rule and the admin derivatives moved here from the Mind exporter,
which asks for them; its curation stays there.

Redaction lives here too. ``package`` is how memory text leaves the
Runtime: ``allows`` on every path an item names, then ``redact`` strips the
names of the documents held from a non-admin reader in a scope that applies
every class (a hand-over; a read under roster-v1). ``Redactor`` finds those
names for the projection and for reads alike; the exporter strips its own
withheld set with ``strip_names``.

``verdicts`` classifies a memory tree. Its cache,
``cache_path``, in this user's home, can be written by any process of
this user, so it is a hint for the operator's own reads and slot only: every
other principal recomputes with ``trust_cache=False``.

``tree`` with that trust also keeps a verdict index beside the hint
(``index_path``): the verdicts of one walk, by hashed path and content
digest, under the digest of every document's path, size, times and inode.
A later process whose walk matches reads it back instead of reading and
parsing memory again; a file changed shortly before that walk is hashed
again first (``RACY_NS``). Builds of one memory take turns, so each memory
state is built once per machine.
"""

from __future__ import annotations

import atexit
from contextlib import contextmanager
from contextvars import ContextVar
from dataclasses import dataclass, fields, is_dataclass, replace
import fcntl
from functools import lru_cache
import hashlib
import html
import json
import math
import os
from pathlib import Path
import re
import stat
import subprocess
import time
from collections import Counter
from typing import Any, Callable, Iterable, Mapping
import unicodedata
from urllib.parse import unquote

from .artifacts import ArtifactSchemaError, artifact_id_from_path, canonical_artifact_id, split_frontmatter
from .errors import EgregoreRuntimeError


class BoundedReadUnavailable(ValueError):
    """No partial hold projection is an authority result."""


@dataclass(frozen=True, slots=True)
class HoldReadLimits:
    entries: int = 16384
    documents: int = 4096
    dependency_bytes: int = 256 * 1024
    total_bytes: int = 32 * 1024 * 1024
    inventory_bytes: int = 4 * 1024 * 1024
    path_bytes: int = 4096
    link_hops: int = 40
    passes: int = 64
    work: int = 256 * 1024 * 1024
    settings_bytes: int = 64 * 1024
    total_settings_bytes: int = 256 * 1024
    selected_bytes: int = 8 * 1024 * 1024
    seconds: float = 8.0


DEFAULT_HOLD_READ_LIMITS = HoldReadLimits()


class _HoldReadBudget:
    __slots__ = ("limits", "deadline", "counts", "rechecking", "invalid", "authority")

    def __init__(self, limits, deadline):
        self.limits, self.deadline = limits, deadline
        self.counts, self.rechecking, self.invalid, self.authority = {}, False, False, {}

    def fail(self):
        self.invalid = True
        raise BoundedReadUnavailable("bounded read unavailable")

    def remaining(self):
        if self.invalid or (remaining := self.deadline - time.monotonic()) <= 0:
            self.fail()
        return remaining

    def charge(self, name, amount=1):
        self.remaining()
        if type(amount) is not int or amount < 0:
            self.fail()
        ceiling = getattr(self.limits, name)
        if name in {"total_bytes", "selected_bytes"} and not self.rechecking:
            ceiling //= 2
        self.counts[name] = self.counts.get(name, 0) + amount
        if self.counts[name] > ceiling:
            self.fail()

    def recheck(self):
        self.remaining()
        if self.rechecking:
            self.fail()
        self.rechecking = True

    def bind_authority(self, key, witness):
        self.remaining()
        if key in self.authority and self.authority[key] != witness:
            self.fail()
        self.authority[key] = witness


def new_read_budget(*, limits=DEFAULT_HOLD_READ_LIMITS, deadline_monotonic=None):
    if type(limits) is not HoldReadLimits:
        raise BoundedReadUnavailable("bounded read unavailable")
    for item in fields(limits):
        value = getattr(limits, item.name)
        valid = (type(value) in (int, float) and math.isfinite(value) if item.name == "seconds"
                 else type(value) is int)
        if not valid or not 0 < value <= getattr(DEFAULT_HOLD_READ_LIMITS, item.name):
            raise BoundedReadUnavailable("bounded read unavailable")
    now = time.monotonic()
    if deadline_monotonic is not None and (type(deadline_monotonic) not in (int, float)
                                          or not math.isfinite(deadline_monotonic)):
        raise BoundedReadUnavailable("bounded read unavailable")
    budget = _HoldReadBudget(limits, min(now + limits.seconds, deadline_monotonic) if deadline_monotonic is not None else now + limits.seconds)
    budget.remaining()
    return budget


def _read_budget(budget):
    if type(budget) is not _HoldReadBudget:
        raise BoundedReadUnavailable("bounded read unavailable")
    budget.remaining()
    return budget


_WORK_BUDGET = ContextVar("egregore_bounded_hold_work", default=None)


def _work(value=0):
    if (budget := _WORK_BUDGET.get()) is not None:
        budget.charge("work", 1 + (len(value) if isinstance(value, (str, bytes)) else value))

_FRONTMATTER_ADMIN = re.compile(r"^\s*admin:\s*[\"']?true[\"']?\s*$", re.MULTILINE)
_HEAD_BYTES = 4096
try:  # this module and the two a verdict reads documents through: frontmatter, and the map's internal events
    _SOURCE = b"".join((Path(__file__).parent / name).read_bytes() for name in ("held.py", "artifacts.py", "eligibility.py"))
except OSError:
    _SOURCE = b""
# Any edit to these modules re-checks every cached verdict, here, in the verdict index and in the exporter's
# parse cache.
HELD_RULES_VERSION = "held-rules/2:" + hashlib.sha256(_SOURCE).hexdigest()[:16]


def document_is_admin(text: str) -> bool:
    """True when the document's YAML frontmatter declares ``admin: true``."""

    if "\r" in text:  # CRLF or bare CR line ends read as on disk
        text = text.replace("\r\n", "\n").replace("\r", "\n")
    if not text.startswith("---"):
        return False
    end = text.find("\n---", 3)
    head = text[3:end] if end != -1 else text[3:_HEAD_BYTES]
    return bool(_FRONTMATTER_ADMIN.search(head))


# Class 1, then the rule classes in the exporter's order (noise, curation, sits between 2 and 3 there).
CLASS_NAMES = {1: "admin: true", 2: "paperwork", 3: "personnel or equity", 4: "raw transcript", 5: "fundraising",
               6: "restriction", 7: "private prose", 8: "personnel change", 9: "derived from an admin document"}


def text_classes(text: str, rel: str | None = None) -> tuple[int, ...]:
    """Class 1, or the first rule's class at memory path ``rel`` (no path: class 1 only; derivatives:
    ``Tree.classes``)."""
    if document_is_admin(text):
        return (1,)
    name = _rule(rel, text) if rel is not None else None
    return (RULE_CLASS[name],) if name else ()


def blob_classes(data: bytes, rel: str | None = None) -> tuple[int, ...]:
    """Classify committed bytes exactly as the same file on disk, and the rules as the exporter reads it."""
    text = data.decode("utf-8", "replace")
    if rel is None:
        return text_classes(text.replace("\r\n", "\n").replace("\r", "\n")[:_HEAD_BYTES])
    return text_classes(text, rel)


def admin_class(data: bytes) -> tuple[int, ...]:
    """Class 1 of a document's whole bytes, read as ``Tree.classes`` reads it: (1,) or ()."""
    return (1,) if document_is_admin(data.decode("utf-8", errors="replace")) else ()


def classes(path: Path) -> tuple[int, ...]:
    """Classify a regular file; missing or unreadable files have no known hold."""
    try:
        if path.is_file():
            with path.open(encoding="utf-8", errors="replace") as handle:
                return text_classes(handle.read(_HEAD_BYTES))
    except (OSError, RuntimeError, ValueError):
        pass
    return ()


def held_class(path: Path) -> int | None:
    return next(iter(classes(path)), None)


LENIENT = frozenset({"all-access-v1", "roster-v1-shadow"})  # the read policies that hold class 1 alone, unredacted


def judge(scope: str, policy: str, found: tuple[int, ...], released: bool) -> tuple[int | None, int | None]:
    """(the class that holds, the class roster-v1 alone would hold) for a non-admin.

    A hand-over applies every class under every policy; reads apply class 1
    under all-access-v1 and roster-v1-shadow, and every class otherwise.
    ``access.release`` lifts rule classes, never class 1.
    """
    live = [number for number in found if number == 1 or not released]
    lenient = scope == "read" and policy in LENIENT
    hold = next((number for number in live if number == 1 or not lenient), None)
    shadow = next((number for number in live if number != 1), None) if policy == "roster-v1-shadow" and scope == "read" else None
    return hold, None if hold else shadow


class _lazy:
    """A pattern compiled on first use, so importing the Runtime does not compile every rule."""

    __slots__ = ("_args", "_pattern")

    def __init__(self, *args):
        self._args, self._pattern = args, None

    def __getattr__(self, name):
        if self._pattern is None:
            self._pattern = re.compile(*self._args)
        return getattr(self._pattern, name)


@lru_cache(maxsize=65536)
def fold(text: str) -> str:
    """Casefold and strip accents (Çağrı -> cagri, Öztürk -> ozturk)."""
    text = str(text)
    if not text.isascii():
        text = unicodedata.normalize("NFKD", text)
        text = text.translate({ord(ch):None for ch in set(text) if unicodedata.combining(ch)})
    return " ".join(text.casefold().replace("ı", "i").split())


# -- The hold rules, moved from experiments/egregore-mind/export.py at 45257e4b ----------------

# Each rule describes a record, not an incidental word in a discussion's body.
PAPERWORK_RULES = [(name, _lazy(pattern, re.I)) for name, pattern in (
    ("tax-record", r"\b(?:tax (?:returns?|assessments?|filings?|paperwork|records?|forms?)|steuer(?:bescheid|erklarung|erklärung))\b"),
    ("tax-claim", r"\b(?:tax|tax credit|research credit|fzul|forschungszulage)\b.*\b(?:claims?|follow up|correspondence|filing|application|evidence|nachforderung)\b|\b(?:claims?|follow up|correspondence|nachforderung)\b.*\b(?:tax|fzul|forschungszulage)\b"),
    ("tax-credit-submission", r"\b(?:fzul|forschungszulage|research tax credit)\b.*\b(?:20\d\d|workbook|answers?|submission|einreichfassung|fassung|review)\b"),
    ("insurance-record", r"\b(?:insurance|krankenkasse)\b.*\b(?:policy|policies|claim|premium|reimbursement|correspondence|correction|contacts?|details|paperwork)\b|\b(?:policy|claim|contacts?|correspondence|paperwork)\b.*\b(?:insurance|krankenkasse)\b"),
    ("invoice-record", r"\b(?:invoice (?:\d+|number|amount|payment|record|paperwork)|(?:vendor|supplier|customer|paid|unpaid) invoice)\b"),
    ("bank-record", r"\bbank (?:statement|details|transfer receipt|paperwork)\b|\b(?:company|personal|corporate) bank account\b"),
    ("registration-record", r"\b(?:(?:company|corporate|business) registration|registration (?:certificate|details|number|paperwork)|commercial register)\b"),
    ("payroll-record", r"\b(?:payroll|salary|compensation)\b.*\b(?:statement|record|slip|payment|paperwork|ledger)\b|\b(?:payslips?|offer letters?|cap tables?|vesting schedule)\b"),
    ("signed-contract", r"\b(?:signed|executed|countersigned)\b.*\b(?:contracts?|agreements?|nda)\b|\b(?:contracts?|agreements?|nda)\b.*\b(?:signed|executed|counterparties|paperwork)\b|\b(?:employment contract|non disclosure agreement)\b"),
    ("private-contact-list", r"\b(?:vc|investor) (?:contact|intro|introduction)s?\b.*\b(?:list|shortlist|questions)\b|\b(?:list|shortlist)\b.*\b(?:vc|investor) contacts?\b"),
    ("personal-administration", r"\bops todos\b|\b(?:private|personal)\b.*\bletter parser\b|\bletter parser\b.*\b(?:private|personal|insurance|krankenkasse)\b"),
    ("correspondence-processing", r"\bletter (?:parser|processing) skill\b"),
)]


def paperwork_rule(fm, rel):
    subject = " ".join(str(fm.get(key) or "") for key in ("title", "topics")) + " " + rel
    subject = " ".join(re.sub(r"[^\w]+", " ", fold(subject)).split())
    return next((name for name, pattern in PAPERWORK_RULES if pattern.search(subject)), None)


# The members hold approved on Oct 9 (the SENSITIVE rule of that day, word for word): personnel and
# equity material is held wherever a document mentions it (frontmatter, body, title, summary or
# path), not only when its subject names a record. The paperwork rules above still apply as well.
PERSONNEL = _lazy(
    r"\b(?:equity|valuations?|compensation|vesting|vested|payroll|salary|salaries|offer letters?|"
    r"cap tables?|stock options?|share options?|esop|severance|"
    r"comp (?:mechanics?|packages?|negotiations?|terms|structure))\b", re.IGNORECASE)


def personnel_rule(text, title="", summary="", rel=""):
    subject = " ".join((text, title, summary, re.sub(r"[-_/.]+", " ", rel)))
    return "personnel-or-equity" if PERSONNEL.search(subject) else None


# Personnel-adjacent material, held by meaning since 2026-10-12 (third audit): who joins, who leaves,
# what investors decided and conflicts between people. The vocabulary is deliberately narrow and was
# reviewed against the corpus: each phrase names a person's move or an investor's outcome, not the
# words in ordinary product prose ("user departure" settings, "leave Egregore and take your files",
# "results fall out of the analysis", "a recruiting note" template).
_NAME = r"[A-Z][A-Za-z’'-]+"
_SUBJECT = r"(?:" + _NAME + r"|[Hh]e|[Ss]he|I|[Tt]hey|[Ww]e)"
PERSONNEL_CHANGE = _lazy("|".join((
    r"\b(?:he|she|they|we|I|[A-Z][A-Za-z’'-]+)\s+(?:(?:is|was|are|were|has|had|have|will|be)\s+){0,3}"
    r"(?:leave|leaving|left|leaves|quit|quits|resign(?:ed|s|ing)?\s+from)\s+(?:the|our)\s+(?:company|team)\b",
    r"\bfounding[- ](?:team |role |equity )?offers?\b",
    r"\b(?:job|employment|hiring) offers?\b",
    r"(?-i:\boffer(?:ed|ing|s)?[ \t]+(?:him|her|them|[A-Z][a-z]+)[ \t]+(?:a[ \t]+|the[ \t]+)?"
    r"(?:role|position|seat|job|co-?founder\w*|founding[ \t]+\w+|partnership)\b)",
    r"\bjoin(?:s|ed|ing)?\s+(?:us\s+|the team\s+|the company\s+)?as\s+(?:a\s+|an\s+|our\s+|the\s+)?"
    r"(?:co-?founder|founding \w+|cto|ceo|coo|cpo|cfo|chief \w+|head of \w+|vp|full[- ]time \w+|"
    r"part[- ]time \w+|employee|first hire)\b",
    r"\brecruit(?:ment|ing) (?:conversation|call|pitch|attempt|offer)s?\b",
    r"\b(?:hir(?:e|ed|es|ing)|recruit(?:ed|s|ing)?)[ \t]+(?-i:" + _NAME + r")\b",
    r"\b(?-i:" + _SUBJECT + r")\s+(?:(?:is|was|are|were|has|had|have|will|be)\s+){0,3}(?:leave|leaving|left|leaves|quit|quits|resign(?:ed|s|ing)?\s+from)\s+"
    r"(?:the company|the team|our company|our team|(?-i:" + _NAME + r"(?:[ \t]+" + _NAME + r")*))\b",
    r"\b(?-i:" + _SUBJECT + r")\s+(?:is\s+|was\s+|will\s+|has\s+)?step(?:s|ped|ping)?\s+(?:down|back)\s+from\b",
    r"\b(?-i:" + _NAME + r")['’]s\s+(?:departure|resignation)\b",
    r"\b(?:departure|resignation) of (?:a |the |our )?(?:co-?)?founder\b",
    r"\b(?:is|was|are|were|currently|temporarily)\s+(?:currently\s+|temporarily\s+)?between jobs\b",
)), re.I)
# A founder handover is held by its title, summary or kind, not by a closing note that mentions one.
FOUNDER_HANDOVER = _lazy(r"\b(?:co-?)?founder[- ]hand(?:over|off)\b", re.I)
INVESTOR_OUTCOME = _lazy("|".join((
    r"\b(?:passed|declined|rejected|pass(?:es)?|declines?) on (?:the |our |this |us )?(?:current |seed |pre-seed )?"
    r"(?:round|raise|deal|investment)\b",
    r"\b(?:decided|chose|decides|choosing) (?:not to|against) invest\w*\b",
    r"\b(?:investor|vc|fund|angel)s?['’]s?\s+(?:rejection|pass|decline|commitment)\b",
    r"\b(?:investors?|vcs?|fund|angels?|lead)\s+(?:has\s+|have\s+|had\s+)?(?:passed|declined|turned (?:us )?down|committed)\b",
    r"\bcommitted (?:to|in) (?:the|our|this) (?:round|raise)\b",
)), re.I)
# "<Name>'s rejection" counts in a document that speaks of investing at all.
NAMED_REJECTION = _lazy(r"\b[A-Z][A-Za-z0-9&]+['’]s\s+(?:rejection|pass)\b")
INVESTING = _lazy(r"\binvest\w*|\bVCs?\b|\bfundrais\w*|\b(?:seed|pre-seed) round\b", re.I)
INVESTOR_KINDS = {"investor-decision", "investor-outcome", "investor_decision", "investor_outcome"}
INTERPERSONAL = _lazy("|".join((
    r"\b(?:co-?founder|business partner|ex-?partner)s?\s+confront(?:ed|s|ing)?\s+\w+\b",
    r"\bconfront(?:ed|s|ing)?\s+(?:him|her|them|me|us)\b",
    r"\bconfront(?:ed|s|ing)?\s+(?-i:" + _NAME + r")\b",
    r"\bfalling[- ]out (?:with|between)\b|\bfell out with\b|\bhad a falling[- ]out\b",
    r"\b(?:conflict|dispute|fight|tension)s? (?:with|between) (?:his|her|my|our|their|the) "
    r"(?:co-?founders?|business partners?|ex-?partners?)\b",
)), re.I)


def personnel_change_rule(text, title="", summary="", fm=None):
    """personnel-change, investor-outcome, interpersonal-conflict, or None."""
    fm = fm or {}
    kinds = {str(fm.get(key) or "").strip().lower() for key in ("kind", "type", "record_type")}
    subject = "\n".join((title or "", summary or "", text or ""))
    if (PERSONNEL_CHANGE.search(subject) or kinds & {"founder-handover", "founder_handover"}
            or FOUNDER_HANDOVER.search("\n".join((title or "", summary or "")))):
        return "personnel-change"
    if (kinds & INVESTOR_KINDS or INVESTOR_OUTCOME.search(subject)
            or (NAMED_REJECTION.search(subject) and INVESTING.search(subject))):
        return "investor-outcome"
    if INTERPERSONAL.search(subject):
        return "interpersonal-conflict"
    return None


# The members hold extended on 2026-10-12 (owner decision after the second privacy audit). Like the
# personnel rule it reads the whole document, but it holds by meaning, not by a single word:
#   valuation-or-dilution: the instruments and terms of a raise (pre-/post-money, valuation cap,
#     convertible note, a SAFE as an uppercase word in a funding phrase, term sheet, cap table,
#     dilution of ownership), an equity percentage ("10% of the company", "~10% dilution"), or a
#     raise-sized amount within a few words of a percentage on a line about the raise;
#   fundraising-figures: a raise-sized amount within a few words of the raise, a soft commitment,
#     an investor's fund, ticket or check size.
# A raise-sized amount carries a currency and is at least 100,000 ("$4M", "€500k–3M", "$4,000,000");
# prices, per-user costs and token counts are not.
MONEY = _lazy(
    r"(?:[$€£]\s?~?(\d[\d,.]*)(?:\s?([kKmMbB]n?|million|billion)\b)?"
    r"(?:\s?(?:[–-]|to)\s?[$€£]?(\d[\d,.]*)(?:\s?([kKmMbB]n?|million|billion)\b)?)?"
    r"|\b(\d[\d,.]*)(?:\s?([kKmMbB]n?|million|billion))?\s?(?:USD|EUR|GBP|dollars|euros)\b)")
_SCALE = {"k": 1e3, "m": 1e6, "mn": 1e6, "million": 1e6, "b": 1e9, "bn": 1e9, "billion": 1e9}
RAISE_SIZED = 100_000
PERCENT = _lazy(r"[<>~≈]?\s?\d+(?:[.,]\d+)?\s?%")
EQUITY_TERMS = _lazy(
    r"\b(?:pre|post)[- ]?money\b|\bvaluation caps?\b|\bconvertible (?:notes?|loans?)\b|\bterm[- ]?sheets?\b|"
    r"\bcap[- ]?tables?\b|\banti[- ]?dilution\b|"
    r"\bdilut\w*\s+(?:(?:our|the|their|founders?['’]?|existing)\s+)?(?:ownership|equity|stakes?|shares?|shareholders?|founders?)\b|"
    r"\d(?:[.,]\d+)?\s?%\s+(?:dilution|of (?:the|our) (?:company|business)|(?:equity )?stake|equity)\b|"
    r"\bdilution\s+(?:of\s+)?(?:about\s+|around\s+|roughly\s+|under\s+|below\s+|~|<)?\s*\d+(?:[.,]\d+)?\s?%|"
    r"\b(?:sell|selling|sold|give up|giving up)\s+(?:about\s+|around\s+|roughly\s+|~)?\d+(?:[.,]\d+)?\s?%", re.I)
# "SAFE" as the instrument: uppercase, in a funding phrase ("on a SAFE", "SAFE note"), or next to an amount.
SAFE_TERM = _lazy(r"\b(?:[Aa]n?|[Tt]he|on|via|uncapped|capped|check|angel)\s+SAFEs?\b|"
                       r"\bSAFEs?\s+(?:notes?|rounds?|raise|agreements?|investments?|terms|caps?|financing|instruments?)\b")
SAFE_WORD = _lazy(r"\bSAFEs?\b")
RAISE_CONTEXT = _lazy(r"\bSAFEs?\b|(?i:(?<![\w-])(?:dilut\w*|equity|stakes?|valuation|valued|raise|raising|rounds?|"
                           r"ask|sold|selling|pre-?seed|(?:pre|post)[- ]?money)(?![\w-])|\bof (?:the|our) company\b)")
# "raised" is left out: it mostly reports another company's past round ("X raised $8M"). "seed" counts
# only as our round ("$4M seed →", "$240k seed for…", "seed capital"), not "$2.6M seed (their investors)".
# "fundraising" itself and investor or VC wording count as well (2026-10-12, third audit); "funds"
# does not, because "a $2.6M seed (two funds)" reports another company's round.
FUNDRAISING_TERM = _lazy(
    r"(?<![\w-])(?:soft[- ]?commit\w*|tickets?|checks?|check size|sweet spot|rounds?|raise|raising|pre-?seed|"
    r"seed(?=[\s*_]*(?:→|->|(?:round|raise|capital|funding|for)\b))|fund|ask|lead investor|fundrais\w*|"
    r"investors?|VCs?|angels?)(?![\w-])", re.I)
FEW_WORDS = _lazy(r"[^\W_]+")
CONTEXT_WORDS = 6
# An investor's fund size within one clause of the amount ("eight VC inbounds: pre-seed funds plus
# Alpha ($1B, Berlin)"): a raise-sized amount and investor wording in the same clause. Clauses end
# at sentence or clause punctuation, a spaced dash, a line or a table cell. Bare "fund", "funds" and
# "seed" are not investor wording here: "willingness to fund this work", "a $2.6M seed (two funds)".
INVESTOR_WORDING = _lazy(
    r"(?<![\w.-])(?:VCs?|investors?|angels?|LPs?|AUM|family offices?|under management|fundrais\w*|pre-?seed|"
    r"venture (?:capital|firms?|funds?))(?![\w-])", re.I)
CLAUSE_BREAK = _lazy(r"(?<=[.;:!?])\s+|\s+[—–-]\s+|—")


def _amount(number: str, scale: str | None) -> float:
    number = number.rstrip(".,")
    if re.fullmatch(r"\d{1,3}(?:([.,])\d{3})(?:\1\d{3})*", number):
        value = float(re.sub(r"[.,]", "", number))
    else:
        try:
            value = float(number.replace(",", ""))
        except ValueError:
            return 0.0
    return value * _SCALE.get((scale or "").lower(), 1)


def raise_amounts(segment: str):
    """Spans of currency amounts of at least RAISE_SIZED (the upper bound of a range counts)."""
    for match in MONEY.finditer(segment):
        a, a_scale, b, b_scale, c, c_scale = match.groups()
        if c is not None:
            value = _amount(c, c_scale)
        else:
            value = max(_amount(a, a_scale or b_scale), _amount(b, b_scale) if b else 0)
        if value >= RAISE_SIZED:
            yield match.start(), match.end()


def _within_words(segment: str, first: tuple[int, int], second: tuple[int, int], words: int) -> bool:
    """Whether at most ``words`` words stand between two spans of one segment."""
    (a, b), (c, d) = sorted((first, second))
    return c >= b and len(FEW_WORDS.findall(segment[b:c])) <= words


def _around(segment: str, first: tuple[int, int], second: tuple[int, int], words: int) -> str:
    """The text of two spans and up to ``words`` words on either side of them."""
    start, end = min(first[0], second[0]), max(first[1], second[1])
    before = [m.start() for m in FEW_WORDS.finditer(segment[:start])][-words:]
    after = [m.end() for m in FEW_WORDS.finditer(segment, end)][:words]
    return segment[before[0] if before else start:after[-1] if after else end]


def fundraising_rule(text, title="", summary=""):
    """valuation-or-dilution, fundraising-figures, or None; lines and table cells are separate segments."""
    subject = "\n".join((title, summary, text))
    if EQUITY_TERMS.search(subject) or SAFE_TERM.search(subject):
        return "valuation-or-dilution"
    figures = False
    for segment in re.split(r"[\n|]", subject):
        amounts = list(raise_amounts(segment))
        if not amounts:
            continue
        spans = [m.span() for m in SAFE_WORD.finditer(segment)]
        if any(_within_words(segment, money, safe, 3) for money in amounts for safe in spans):
            return "valuation-or-dilution"
        if any(_within_words(segment, money, m.span(), CONTEXT_WORDS)
               and RAISE_CONTEXT.search(_around(segment, money, m.span(), CONTEXT_WORDS))
               for money in amounts for m in PERCENT.finditer(segment)):
            return "valuation-or-dilution"
        if any(_within_words(segment, money, m.span(), 3) for money in amounts for m in FUNDRAISING_TERM.finditer(segment)):
            figures = True
        elif any(INVESTOR_WORDING.search(clause) and any(raise_amounts(clause))
                 for clause in CLAUSE_BREAK.split(segment)):
            figures = True
    return "fundraising-figures" if figures else None


# -- Restriction, private prose and transcripts, moved from experiments/egregore-mind/export.py at
# 45257e4b. names_people reads the exporter's ordinary words through strings_in; both are copied
# verbatim below, and test_held.py fails when they drift apart.
def strings_in(value) -> list[str]:
    if value is None or isinstance(value, bool):
        return []
    if isinstance(value, str):
        return [value]
    if isinstance(value, (int, float)):
        return [str(value)]
    if isinstance(value, dict):
        out = []
        for key in sorted(value, key=str):
            out.extend(strings_in(value[key]))
        return out
    if isinstance(value, (list, tuple)):
        out = []
        for item in value:
            out.extend(strings_in(item))
        return out
    return [str(value)]


ENGLISH_STOP = set("""
a about above across actually after again against all almost along already also although always am among an and
another any anybody anyone anything anyway anywhere are aren around as ask asked asks at away back be became because
become becomes been before behind being below beside besides between beyond both but by came can cannot cant could
couldn did didn different do does doesn doing don done down during each either else elsewhere enough especially even
ever every everyone everything exactly except far few for former from further get gets getting give given gives
go goes going gone got gotten had hadn happen has hasn have haven having he hence her here hers herself him himself his
how however i ie if in inside instead into is isn it its itself just keep keeps kept know known knows last later least
less let lets like likely made make makes making many may maybe me meanwhile might mine more moreover most mostly much
must my myself near nearly need needed needs neither never nevertheless no nobody non none nor not nothing now nowhere
of off often oh ok okay on once one ones only onto or other others otherwise ought our ours ourselves out outside over
own per perhaps please put quite rather really said same say saying says see seem seemed seems seen several shall she
should shouldn since so some somebody somehow someone something sometime sometimes somewhat somewhere soon still such
sure take taken takes than that thats the their theirs them themselves then there thereby therefore these they thing
things this those though through throughout thus to together too took toward towards try trying under unless unlike
until up upon us use used useful uses using usually various very via was wasn way ways we well went were weren what
whatever when whenever where whereas wherever whether which while who whoever whole whom whose why will with within
without won would wouldn yes yet you your yours yourself yourselves etc e.g eg vs versus also within within upon
able across along among around beyond done each every here there want wants wanted lot lots bit kind sort really
""".split())
LABEL_GENERIC = set("""
decision decisions finding findings pattern patterns research document documents doc docs note notes summary
summaries context status update updates updated work works worked working team teams people person user users
system systems thing approach approaches question questions plan plans planning issue issues draft drafts drafted
version versions change changes changed review reviews reviewed idea ideas point points current currently next step
steps first second third new old good better best important key main core part parts level levels type types case
cases example examples problem problems time times day days week weeks weekly month months year years now value
values result results number numbers list lists item items section sections page pages file files line lines text
content contents thought thoughts reflection reflections finding wrap wraps open opened close closed closing start
started starting end ended ending done todo todos task tasks action actions owner owners author authors source
sources reference references link links title titles topic topics tag tags format formats template templates spec
specs feature features fix fixes fixed add added adds adding remove removed removes create created creates creating
build built builds building run runs running ran test tests tested testing check checks checked note noted output
outputs input inputs set sets setting settings support supports supported mode modes path paths name names named
call calls called flow flows state states based base layer layers default defaults option options process processes
direction directions specific general simple complex clear real actual full total single multiple across overall
model models framework frameworks structure structures thinking think thinks thought understanding understand
make makes making made right wrong high low long short small large big early late previous following follow follows
whole across inside outside question answer answers answered discussion discuss discussed meeting meetings call
proposal proposed propose proposes doc document captured capture captures record records recorded log logs logged
agent agents claude human humans conversation conversations repo repos repository commit commits branch branches
two three four five six seven eight nine ten related relevant ago min mins minute minutes hour hours sec secs
seconds org orgs organization organizations organizational knowledge project projects entry entries url urls dev
graph graphs neo neo4j cypher evidence surface surfaces command commands product products strategy strategies
shared individual within without another however across instead around including include includes included
specification asked ask asks session sessions handoff handoffs today yesterday active inactive pending complete
completed signal signals align aligned alignment framework approach mechanism mechanisms concept concepts
lead leads card cards brief briefs query queries tool tools read reads live gate gates mark marks remains remain
bin init bump zero view views activity quest quests code substrate data stack layer surface create stab ripcord
transcript transcripts capture captured attendant recorder flight dashboard session develop main skill skills
remember remembering writes write written image images displayed display original merged merging analyzing
cross chunk chunks rest persist persists persisted prime reading respect receive
share shared worth keeping works stated self improvement feel character application applications client clients
customer customers business offer offers enterprise vision tech intelligence architecture pipeline pipelines
""".split())


# Restrictions authors write. A restriction field that names specific people ("audience: Ada and
# Bo", "for: [ada]") or says private, confidential, founders or not for sharing holds the document;
# so does "not for sharing" or "do not share" in the title or the opening lines of the body.
# A document is never held merely for mentioning a person, and ``to``/``author`` are not restrictions.
RESTRICTION_KEYS = ("audience", "visibility", "share", "sharing", "shared_with", "for", "restricted",
                    "restricted_to", "access", "confidentiality", "distribution", "private", "confidential")
RESTRICTION_FLAGS = ("private", "confidential", "restricted")
RESTRICTED_MARKING = _lazy(
    r"\b(?:private|confidential|founders?(?:[- ]only)?|restricted|secret|eyes[- ]only|personal|"
    r"not (?:for|to be) (?:shared|sharing|distribution|distributed|circulation|circulated)|"
    r"do not (?:share|distribute|circulate|forward))\b", re.I)
NOT_FOR_SHARING = _lazy(
    r"\bnot (?:for|to be) (?:sharing|shared|distribution|distributed|circulation|circulated)\b|"
    r"\b(?:do not|don['’]t|never) (?:share|distribute|circulate|forward)"
    r"(?=\s*(?:[.!,;:)\]—–-]|$|(?:this|these|it|outside|beyond|with|externally|publicly|further|widely|any ?more)\b))",
    re.I | re.M)
OPENING_LINES = 5
# A confidentiality banner (2026-10-12): a title or one of the opening body lines in which, once
# markdown emphasis is removed, one piece between separators is only the marking
# ("**February 2026 | Confidential**", "> INTERNAL ONLY", "Classification: Founders only").
# A marking inside a sentence ("a founder-only invitation stage", "high confidentiality
# requirements") is not a banner.
BANNER = _lazy(
    r"(?:strictly |highly )?(?:private (?:and|&) )?confidential(?: (?:draft|document|memo|material))?|"
    r"(?:for )?internal(?: use)? only|(?:co-?)?founders?['’]?(?: eyes)? only|(?:co-?)?founder[- ]only|"
    r"not for (?:distribution|circulation|sharing)|do not (?:distribute|circulate|forward|share)|"
    r"(?:private|restricted)(?: (?:and|&) confidential)?|eyes only", re.I)
BANNER_SPLIT = _lazy(r"\s*(?:[|·•:;,()\[\]]|\s[—–-]\s|—)\s*")


def banner_marking(line: str) -> bool:
    plain_line = re.sub(r"[*_`#>~]+|^\s*[-+]\s+", " ", line or "")
    plain_line = re.sub(r"[\U0001F300-\U0001FAFF☀-➿]", " ", plain_line)
    return any(BANNER.fullmatch(" ".join(piece.split()).strip(" .!")) for piece in BANNER_SPLIT.split(plain_line))


# Words of a restriction value that describe a group or a use, not a person.
AUDIENCE_WORDS = set("""
org organization organisation orgs team teams all everyone everybody anyone member members internal public
company companies staff employee employees investor investors partner partners client clients customer customers
external grant grants application applications deck decks reference references comms communication communications
product products technical tech engineering engineers developers developer designers designer data room rooms
community communities user users reader readers general shared wide prep facing board advisors advisor
collaborators collaborator contributors contributor operators operator admins admin owners owner maintainers
maintainer leadership management ops sales marketing research researchers press media web site newsletter social
followers audience agents agent humans human people self myself future me us we you next session sessions
review reviewers reviewer legal finance funding funders stakeholders stakeholder ecosystem network friends
alpha beta testers tester pilot pilots partners prospects prospect lead leads leadership executive executives
founder founders cofounders public-facing investor-facing org-wide team-wide company-wide any none open closed
password gated encrypted link links the and for of to in on with only
""".split())


def _value_text(value) -> str:
    return " ; ".join(strings_in(value)) if not isinstance(value, str) else value


def names_people(value) -> bool:
    """A restriction value that names a person: an entry of one or two words of two or more letters,
    none of them a group, role, use or ordinary word and none an all-capitals acronym. Parenthesised
    notes ("Ada (form review)") are not entries."""
    text = re.sub(r"\([^)]*\)", " ", _value_text(value)).replace("[", " ").replace("]", " ")
    ordinary = AUDIENCE_WORDS | ENGLISH_STOP | LABEL_GENERIC
    for entry in re.split(r"[,;/+&|]|\band\b|\bor\b", text, flags=re.I):
        words = re.findall(r"[^\W\d_]+", entry)
        if not 1 <= len(words) <= 2 or len(entry.strip()) > 40:
            continue
        if any(len(w) < 2 or fold(w) in ordinary or w.isupper() for w in words):
            continue
        return True
    return False


def restriction_rule(fm, title, body):
    """restricted-audience, restricted-marking, not-for-sharing, or None."""
    for key in RESTRICTION_KEYS:
        value = fm.get(key)
        if value is None or value == "" or value == []:
            continue
        flag = value is True or str(value).strip().lower() in {"true", "yes"}
        refused = value is False or str(value).strip().lower() in {"false", "no", "none"}
        if (key in RESTRICTION_FLAGS and flag) or (key in {"share", "sharing"} and refused):
            return "restricted-marking"
        if isinstance(value, bool):
            continue
        if RESTRICTED_MARKING.search(_value_text(value)):
            return "restricted-marking"
        if key not in RESTRICTION_FLAGS and names_people(value):
            return "restricted-audience"
    lines = [line for line in (body or "").split("\n") if line.strip()][:OPENING_LINES]
    opening = "\n".join(lines)
    if NOT_FOR_SHARING.search(title or "") or NOT_FOR_SHARING.search(opening):
        return "not-for-sharing"
    raw_title = fm.get("title") if isinstance(fm.get("title"), str) else ""
    if any(banner_marking(line) for line in [title or "", raw_title] + lines):
        return "restricted-marking"
    return None


# Explicit credential assignments disclose access, even when a document is otherwise an ordinary
# handoff. Match the assertion of a value, not discussion of password UX or redacted placeholders.
CREDENTIAL_LABEL = r"(?:password|passphrase|access[-_ ]code|unlock[-_ ]code|api[-_ ]key|access[-_ ]token|secret)"
CREDENTIAL_VALUE = r"(?:`[^`\n]+`|\"[^\"\n]+\"|'[^'\n]+'|[^\s`\"'()<>{}\[\]]+)"
CREDENTIAL_ASSIGNMENT = _lazy(
    r"(?P<label>\b" + CREDENTIAL_LABEL + r"\b)[ \t]*(?P<connector>[:=]|\(|(?:is|was|to)\b|(?=[`\"']))"
    r"[ \t]*(?P<value>" + CREDENTIAL_VALUE + r")|--password(?:=|[ \t]+)(?P<command>" + CREDENTIAL_VALUE + r")", re.I)
CREDENTIAL_NONVALUES = set("""
a an the this that your our their my new old another required optional never not unset empty missing
unchanged rotated hidden redacted removed omitted masked placeholder example encrypted hashed stored
safe secure private secret present available enabled disabled used set needed requested accepted denied
invalid incorrect valid correct supplied provided entered chosen generated kept saved loaded read
unlock open access protect allow enable improve strengthen change reset rotate recover authenticate
string true false null none undefined env environment process os ask ask-me known standard
""".split())
CONTRACT_LIFECYCLE = _lazy(
    r"\bcontract\b[^.\n]{0,80}\b(?:expir(?:e[ds]?|ing|ation)|renew(?:al|ed|ing)?|continuation|extension|"
    r"ends?\s+(?:in|on|next|this))\b", re.I)
PRIVATE_DESCRIPTOR = _lazy(
    r"\bprivate\s+(?:[\w-]+\s+){0,5}(?:brief(?:ing)?|memo|document|report|paper|letter|invitation)\b|"
    r"\bpersonal\s+(?:mentorship|mentoring|coaching|advisory)\s+(?:invitation|letter|message)\b|"
    r"\b(?:liquidity|bridge[- ]financ\w*)\b[^.\n]{0,100}\b(?:brief(?:ing)?|memo|plan)\b"
    r"[^.\n]{0,60}\bfor\s+(?-i:[A-Z][a-z]+)\b", re.I)


def private_prose_rule(text, title="", summary="", fm=None):
    """Hold explicit credentials, personal captures and private-purpose prose for non-admins."""
    if str((fm or {}).get("capture_mode") or "").strip().lower() == "personal":
        return "personal-capture"
    # Read source text, which already includes frontmatter summaries. A derived summary can drop
    # angle-bracket placeholders and line breaks, making the next field look like a secret value.
    subject = "\n".join((title or "", text or summary or ""))
    for match in CREDENTIAL_ASSIGNMENT.finditer(subject):
        raw = match.group("value") or match.group("command") or ""
        quoted = raw.startswith(("`", '"', "'"))
        value = raw.strip("`\"'").rstrip(".,;:!?")
        token = value.lower()
        label = (match.group("label") or "password").lower().replace("_", " ").replace("-", " ")
        connector = match.group("connector") or "="
        # Unquoted natural-language assignments can contain several words. An article
        # alone is not enough to decide that the complete value is harmless.
        clause = re.split(r"[\n.!?;]", subject[match.start("value"):], maxsplit=1)[0].strip() if match.group("value") else value
        if not quoted and connector.lower() in {"is", "was", "to"}:
            descriptive = re.match(r"(?:never|not)\b|(?:required|optional|active|inactive|unset|empty|missing|"
                                   r"unchanged|rotated|hidden|redacted|removed|omitted|masked|encrypted|hashed|"
                                   r"stored|available|enabled|disabled|invalid|incorrect|valid|correct|safe|secure)\b", clause, re.I)
            if descriptive:
                continue
            if re.match(r"(?:a|an|the)\s+\S+", clause, re.I):
                return "access-credential"
            if token == "secret":
                return "access-credential"
        if label not in {"password", "passphrase", "access code", "unlock code"} and not quoted and connector == "(":
            continue  # A type annotation such as "API key (JWT)" asserts no value.
        if connector == "(" and not quoted and not subject[match.end():].lstrip().startswith(")"):
            continue  # A parenthesised instruction such as "password (ask me privately)".
        if (value and re.search(r"[a-z0-9]", token)
                and (quoted or connector in {":", "="} or token not in CREDENTIAL_NONVALUES)
                and not token.startswith(("[", "{", "$", "process.", "os.", "env.", "secrets."))):
            return "access-credential"
    if CONTRACT_LIFECYCLE.search(subject):
        return "contract-lifecycle"
    if PRIVATE_DESCRIPTOR.search(subject):
        return "private-purpose"
    return None


TRANSCRIPT_NAME = _lazy(r"[-_](?:raw|raw[-_]transcript|transcript[-_]raw)$", re.I)
TRANSCRIPT_TYPE_KEYS = ("record_type", "type", "kind")
# Frontmatter a raw capture carries beside a plain "transcript" type: its hash, speaker map or
# preservation note.
RAW_MARKERS = ("raw", "raw_sha256", "raw_hash", "speaker_mapping", "preservation")


def transcript_rule(rel, fm=None):
    """Raw meeting transcripts, whatever else their frontmatter says (2026-10-12): files under a
    meetings/transcripts/ folder, files whose names end in -raw, -raw-transcript or -transcript-raw,
    and frontmatter whose record_type, type or kind is a raw transcript ("raw_transcript",
    "raw-transcript", "transcript-raw") or "transcript" beside a raw marker. Checked after the
    personnel rule, so documents that rule already held keep their recorded rule."""
    folders = [part.lower() for part in Path(rel.removeprefix("memory/")).parts[:-1]]
    if (any(a == "meetings" and b == "transcripts" for a, b in zip(folders, folders[1:]))
            or TRANSCRIPT_NAME.search(Path(rel).stem)):
        return "raw-transcript"
    fm = fm or {}
    for key in TRANSCRIPT_TYPE_KEYS:
        words = set(re.findall(r"[a-z]+", str(fm.get(key) or "").lower()))
        if "transcript" in words and ("raw" in words or (words == {"transcript"} and any(
                fm.get(marker) not in (None, "", [], False) for marker in RAW_MARKERS))):
            return "raw-transcript"
    return None


# -- The exporter's name strippers, moved from experiments/egregore-mind/export.py (H3) ---------
# Summaries shown to anyone but admins quote no memory paths at all: a quoted path can name a
# document that audience does not see (admin-only, held, captured or private), and a path tells a
# reader nothing the node's own place on the map does not.
MEMORY_PATH = _lazy(r"(?<![\w.-])memory/[^\s`'\")\]>,;]*")


def strip_paths(text: str, pattern: re.Pattern = MEMORY_PATH) -> str:
    """Remove every match of ``pattern`` and the empty quotes, brackets and separators it leaves."""
    if not pattern.search(text):
        return text
    text = pattern.sub(lambda m: "…" if m.group().endswith("…") else "", text)
    text = re.sub(r"`\s*`|\(\s*[,;\s]*\)|\[\s*[,;\s]*\]", "", text)
    text = re.sub(r"\s*[,;](?:\s*[,;])+", ",", text)
    text = re.sub(r"\s+([,.;:!?…])", r"\1", text)
    return " ".join(text.split()).strip(" ,;")


def strip_memory_paths(text: str) -> str:
    return strip_paths(text, MEMORY_PATH)


def file_name_pattern(names, slugs=()) -> re.Pattern | None:
    """A withheld document's file name, bare or after any path token ("x.md", "a//b/x.md",
    "~user/x.md", "file:///a/x.md", "https://host/a/x.md"), and its slug without ".md" ("a-b",
    "notes/a-b") when the slug is distinctive (``distinctive_slug``). ``names_in`` and
    ``strip_names`` check the percent-decoded text as well."""
    names = {n for n in names if n}
    slugs = {s for s in slugs if s}
    options = [(n, re.escape(n)) for n in names] + [(s, re.escape(s) + r"(?:\.(?:md|html?))?") for s in slugs]
    if not options:
        return None
    options.sort(key=lambda option: (-len(option[0]), option[0]))
    return re.compile(r"(?<![\w.-])(?:[^\s`'\"()\[\]<>]*/)?(?:" + "|".join(p for _, p in options) + r")(?![\w/-])",
                      re.IGNORECASE)


def spellings(text: str) -> list[str]:
    """The text, then percent- and entity-decoded until it stops changing ("forest%252D3.md",
    "forest&#45;3.md"), at most three passes."""
    found = [text]
    for _ in range(3):
        decoded = html.unescape(unquote(found[-1]))
        if decoded == found[-1]:
            break
        found.append(decoded)
    return found


def names_in(pattern: re.Pattern | None, text: str) -> bool:
    """A withheld name in text, as written or decoded, in any letter case ("Forest-3.md")."""
    return bool(pattern and any(pattern.search(spelling) for spelling in spellings(text)))


def strip_names(text: str, pattern: re.Pattern) -> str:
    """``strip_paths`` for withheld names, decoded spellings included."""
    text = strip_paths(text, pattern)
    decoded = spellings(text)
    return strip_paths(decoded[-1], pattern) if any(pattern.search(d) for d in decoded[1:]) else text


def qualified_names(outside, shown) -> set[str]:
    """For an outside path whose file name a shown document shares, its shortest folder-qualified
    spelling that no shown path ends with ("findings/x.md" beside a shown "findings/ocean/x.md")."""
    shown = [path.removeprefix("memory/") for path in shown]
    names, found = {path.rsplit("/", 1)[-1] for path in shown}, set()
    for parts in (path.removeprefix("memory/").split("/") for path in outside):
        tails = ["/".join(parts[-k:]) for k in range(2, len(parts) + 1)] if parts[-1] in names else []
        found.update(next(([t] for t in tails if not any(p == t or p.endswith("/" + t) for p in shown)), []))
    return found


# -- A document as the exporter reads it -------------------------------------------------------
# Copied verbatim from experiments/egregore-mind/export.py (read_frontmatter, title_for, summary_for
# and their helpers), so a verdict here reads exactly the exporter's words; test_held.py fails when
# the two readings drift apart.
ROLE_MASK = _lazy(r"\[(?:person|organization)\]", re.I)  # mind/organize.py


SUMMARY_KEYS = ("summary", "description", "why_it_matters")
EMAIL = _lazy(r"(?<![\w.+-])[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}")
WEB_LINK = _lazy(r"(?:\b(?:https?|ftp)://|\bwww\.)([^\s/?#)\]>\"'`]+)[^\s)\]>\"'`]*", re.I)
LONG_ID = _lazy(r"\b([0-9a-f]{8})(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b|\b([0-9a-f]{8})[0-9a-f]{24,}\b", re.I)
LOCAL_PATH = _lazy(r"(?:file://)?(?<![\w.~])(?:/Users|/home|/private|/tmp|/var/folders|/Volumes)/[^\s)\]>\"'`,;]*")
SLUG_TITLE = _lazy(r"^(?:([A-Z][\w ]{0,24}):\s+)?([a-z0-9çğıöşüéèáíóúñäë ]+)$")
TLDS = {"com", "io", "ai", "so", "co", "dev", "app", "org", "net", "xyz", "tech", "eu", "de", "tr", "me", "sh",
        "gg", "ly", "us", "uk", "fm", "tv", "to", "cc", "info", "edu", "gov"}
SLUG_PATH_WORDS = {"users", "home", "private", "tmp", "var", "library", "downloads", "desktop", "documents", "file"}
FENCE = _lazy(r"```.*?(?:```|\Z)|~~~.*?(?:~~~|\Z)", re.S)
HTML = _lazy(r"<!--.*?-->|<[^>\n]{1,200}>", re.S)
MDIMAGE = _lazy(r"!\[[^\]]*\]\([^)]*\)")
MDLINK = _lazy(r"\[([^\]]*)\]\([^)]*\)")
WIKILINK = _lazy(r"\[\[([^\]|#]+)(?:#[^\]|]*)?(?:\|([^\]]*))?\]\]")
EMPHASIS = _lazy(r"(\*\*|__|\*|(?<!\w)_|`+|~~)")
FRONTMATTER_LINE = _lazy(r"^([A-Za-z][A-Za-z0-9_-]*):(?:[ \t]*(.*))?$")


def plain(text: str) -> str:
    """Markdown/HTML -> one line of plain text."""
    text = MDIMAGE.sub("", text)
    text = WIKILINK.sub(lambda m: (m.group(2) or m.group(1)).strip(), text)
    text = MDLINK.sub(r"\1", text)
    text = HTML.sub(" ", text)
    text = re.sub(r"^\s{0,3}(?:#{1,6}\s+|>\s?|[-*+]\s+|\d+[.)]\s+)", "", text, flags=re.M)
    text = EMPHASIS.sub("", text)
    return " ".join(text.split())


def clip(text: str, limit: int) -> str:
    text = " ".join(text.split())
    if len(text) <= limit:
        return text
    cut = text[: limit - 1]
    space = cut.rfind(" ")
    if space > limit * 0.6:
        cut = cut[:space]
    return cut.rstrip(" ,;:.-—–") + "…"


def _host(match: re.Match) -> str:
    host = match.group(1).rsplit("@", 1)[-1].split(":", 1)[0].lower().rstrip(".,;:!?")
    return host.removeprefix("www.")


def _last_part(match: re.Match) -> str:
    parts = [p for p in match.group(0).rstrip(".,;:!?").split("/") if p]
    last = parts[-1] if parts else ""
    return "" if _id_like(last) else last


def scrub(text: str) -> str:
    """Emails -> [email], links -> their host, local paths -> their last part, UUIDs and long
    hashes -> their first 8 characters (an emissary or share id works like the link itself)."""
    text = ROLE_MASK.sub("", text)
    text = EMAIL.sub("[email]", text)
    text = WEB_LINK.sub(_host, text)
    text = LOCAL_PATH.sub(_last_part, text)
    text = LONG_ID.sub(lambda m: m.group(1) or m.group(2), text)
    return " ".join(text.split())


def _id_like(word: str) -> bool:
    """Share ids, hashes, tracking parameters; not 'v2', 'b2b', 'pg16', 'gpt4o' or 'qwen3'."""
    digits = sum(ch.isdigit() for ch in word)
    if not digits:
        return False
    if digits == len(word):
        return len(word) >= 5
    hexish = all(ch in "0123456789abcdefABCDEF" for ch in word)
    turns = sum(1 for a, b in zip(word, word[1:]) if a.isdigit() != b.isdigit())
    return (hexish and len(word) >= 4) or turns >= 3 or (turns >= 2 and len(word) >= 8) or len(word) >= 12


def tidy_slug(text: str) -> str:
    """A title made from a slugged prompt ('https chatgpt com s t 6a6e…', 'private tmp claude 501
    users sample …'): hosts collapse to 'chatgpt.com'; ids, local folders and user names drop out."""
    words = text.split()
    pathy = "tmp" in words or sum(w in SLUG_PATH_WORDS for w in words) >= 2
    out: list[str] = []
    i = 0
    while i < len(words):
        w = words[i]
        if w in ("https", "http", "ftp", "www"):
            j = i + 1
            while j < len(words) and words[j] == "www":
                j += 1
            host: list[str] = []
            while j < len(words) and len(host) < 4:
                host.append(words[j])
                j += 1
                if host[-1] in TLDS and len(host) >= 2:
                    break
            if len(host) >= 2 and host[-1] in TLDS:
                out.append(".".join(host))
                i = j
                while i < len(words) and (_id_like(words[i]) or len(words[i]) == 1):
                    i += 1   # the path right after a host: share ids, single-letter route parts
                continue
            i += 1
            continue
        if w in ("users", "home") and i + 1 < len(words) and (
                pathy or (i + 2 < len(words) and words[i + 2] in SLUG_PATH_WORDS | {"claude", "dev", "code"})):
            i += 2           # a local user folder and the user name after it
            continue
        if pathy and w in ("private", "tmp", "var", "file"):
            i += 1
            continue
        if pathy and w == "claude" and i + 1 < len(words) and words[i + 1].isdigit():
            i += 2
            continue
        if not _id_like(w):
            out.append(w)
        i += 1
    return " ".join(out)


def _scalar(raw: str):
    value = raw.strip()
    if not value:
        return None
    try:
        return json.loads(value)
    except (json.JSONDecodeError, ValueError):
        pass
    if value.startswith("[") and value.endswith("]"):
        inner = value[1:-1].strip()
        return [p.strip().strip("\"'") for p in inner.split(",") if p.strip()] if inner else []
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
        return value[1:-1]
    low = value.lower()
    if low in ("true", "false"):
        return low == "true"
    if low in ("null", "~"):
        return None
    return value


def _header(normalized: str) -> str | None:
    if not normalized.startswith("---\n"):
        return None
    closing = normalized.find("\n---\n", 4)
    if closing < 0:
        closing = normalized.find("\n---", 4)
        if closing < 0 or normalized[closing + 4:].strip():
            return None
    return normalized[4:closing]


def _block_lists(header: str, fields: dict) -> dict:
    """Recover YAML block lists (``key:`` followed by ``  - item``) the strict reader skips."""
    current = None
    items: dict[str, list] = {}
    for line in header.splitlines():
        if not line.strip():
            continue
        if not line[:1].isspace():
            match = FRONTMATTER_LINE.match(line)
            current = match.group(1) if match and not (match.group(2) or "").strip() else None
            continue
        if current and fields.get(current) is None:
            item = re.match(r"^\s+-\s+(.*)$", line)
            if item:
                items.setdefault(current, []).append(_scalar(item.group(1)))
    if items:
        fields = dict(fields)
        fields.update(items)
    return fields


def read_frontmatter(text: str, split_frontmatter) -> tuple[dict, str, bool]:
    """Returns (fields, body, lenient). Strict reader first; tolerant fallback."""
    normalized = text.replace("\r\n", "\n").replace("\r", "\n")
    try:
        fields, body = split_frontmatter(normalized)
        if fields and any(v is None for v in fields.values()):
            header = _header(normalized)
            if header is not None:
                fields = _block_lists(header, fields)
        return fields, body, False
    except Exception:  # noqa: BLE001 - legacy files: parse what we can
        header = _header(normalized)
        if header is None:
            return {}, normalized, True
        fields: dict = {}
        for line in header.splitlines():
            if not line.strip() or line[:1].isspace() or line.lstrip().startswith("#"):
                continue
            match = FRONTMATTER_LINE.match(line)
            if match and match.group(1) not in fields:
                fields[match.group(1)] = _scalar(match.group(2) or "")
        fields = _block_lists(header, fields)
        end = normalized.find("\n---", 4)
        body = normalized[end + 4:].lstrip("-").lstrip("\n") if end >= 0 else normalized
        return fields, body, True


def title_for(fm: dict, body: str, rel: str) -> str:
    raw = fm.get("title")
    title = plain(str(raw)) if raw not in (None, "") and not isinstance(raw, (list, dict)) else ""
    if not title:
        heading = re.search(r"(?m)^#\s+(.+?)\s*#*\s*$", body)
        if heading:
            title = plain(heading.group(1))
    if not title:
        stem = rel.rsplit("/", 1)[-1][:-3]
        stem = re.sub(r"^(?:20\d{2}-\d{2}-\d{2}|\d{2})[-_]?", "", stem) or stem
        title = " ".join(re.split(r"[-_]+", stem)).strip()
        title = title[:1].upper() + title[1:]
    title = scrub(title)
    slug = SLUG_TITLE.match(title)
    if slug and len(slug.group(2).split()) >= 3:
        prefix, rest = slug.group(1), tidy_slug(slug.group(2))
        if prefix:   # "Ripcord: <slugged prompt>": keep the kind alone when little survives
            title = f"{prefix}: {rest}" if len(re.findall(r"[^\W\d_]{3,}", rest)) >= 2 else prefix
        elif rest:
            title = rest
    return clip(title, 120)


META_LINE = _lazy(r"^\s*(?:[-*]\s+)?\**[A-Za-z][\w /&'-]{0,32}\**\s*:\**\s")
META_KEY = _lazy(r"^\s*(?:[-*]\s+)?\**([A-Za-z][\w /&'-]{0,32}?)\**\s*:\**\s*(.*)$")
META_NOISE = {"date", "author", "authors", "status", "type", "topics", "tags", "created", "updated", "from", "to",
              "owner", "id", "version", "source", "url", "link", "category", "project", "quest", "quests",
              "urgency", "confidence", "conviction", "time", "duration", "attendees", "participants", "branch",
              "repo", "pr", "base", "session", "started", "ended", "recipient", "addressed to", "kind", "priority"}


def summary_for(fm: dict, body: str) -> str:
    fm_fallback = ""
    for key in SUMMARY_KEYS:
        value = fm.get(key)
        if isinstance(value, str) and value.strip():
            text = scrub(plain(value))
            if len(text) >= 20:
                return clip(text, 220)
            fm_fallback = fm_fallback or text
    text = FENCE.sub("\n\n", body)
    fallback = ""
    meta_fallback = ""
    for block in re.split(r"\n\s*\n", text):
        lines = [line for line in block.strip().splitlines() if line.strip()]
        if not lines:
            continue
        head = lines[0].lstrip()
        if head.startswith(("#", "|", "---", "***", "<!--", "![", "```", "~~~", "[//]")):
            continue
        if all(META_LINE.match(line) for line in lines):
            if not meta_fallback:
                parts = []
                for line in lines:
                    match = META_KEY.match(line)
                    if match and match.group(1).strip().lower() not in META_NOISE and match.group(2).strip():
                        parts.append(f"{match.group(1).strip()}: {match.group(2).strip()}")
                meta_fallback = scrub(plain(" · ".join(parts)))
            continue
        if head.startswith(("- ", "* ", "+ ")) or re.match(r"^\d+[.)]\s", head):
            if not fallback:
                fallback = scrub(plain(" ".join(lines)))
            continue
        candidate = scrub(plain(" ".join(lines)))
        if len(candidate) >= 40:
            return clip(candidate, 220)
        if not fallback and candidate:
            fallback = candidate
    return clip(fallback or meta_fallback or fm_fallback, 220)


def document_rule(rel: str, text: str, fm: dict, body: str, title: str, summary: str, after: int = 1) -> str | None:
    """The first rule past class ``after`` that holds a parsed document, in the exporter's order."""
    _work(text)
    checks = ((2, lambda: paperwork_rule({**fm, "title": title}, rel)), (3, lambda: personnel_rule(text, title, summary, rel)),
              (4, lambda: transcript_rule(rel, fm)), (5, lambda: fundraising_rule(text, title, summary)),
              (6, lambda: restriction_rule(fm, title, body)), (7, lambda: private_prose_rule(text, title, summary, fm)),
              (8, lambda: personnel_change_rule(text, title, summary, fm)))
    return next((name for number, check in checks if number > after and (name := check())), None)


def _parse(rel: str, text: str, summary: bool = True) -> dict:
    """A document as the exporter's members audience reads it (the summary only when asked)."""
    _work(text)
    fm, body, _lenient = read_frontmatter(text, split_frontmatter)
    return {"rel": rel, "fm": fm, "body": body, "title": title_for(fm, body, rel),
            "summary": strip_memory_paths(summary_for(fm, body)) if summary else None}


def _rule(rel: str, text: str) -> str | None:
    """The first rule that holds the document at memory path ``rel``."""
    doc = _parse(rel, text)
    return document_rule(rel, text, doc["fm"], doc["body"], doc["title"], doc["summary"])


def classify(rel: str, text: str) -> str | None:
    """``admin`` (class 1), a rule name, or None for a memory-relative path and its text."""
    return "admin" if document_is_admin(text) else _rule(rel, text)


# -- The admin derivatives, moved from experiments/egregore-mind/export.py at 45257e4b ----------
def distinctive_slug(stem: str) -> bool:
    """A file slug that names one document rather than an ordinary word: two or more hyphenated
    parts, at least eight characters and at least one part of three or more letters."""
    parts = stem.split("-")
    return len(parts) >= 2 and len(stem) >= 8 and all(parts) and any(sum(c.isalpha() for c in p) >= 3 for p in parts)


# A document whose text is wholly or almost wholly inside one admin-only document is a copy of it:
# at least COPY_SHARE of its word COPY_WORDS-grams appear in that one document. Very short documents
# (fewer than COPY_MIN_SHINGLES grams) are left to the other rules.
COPY_RULE = "copy-of-admin-document"
COPY_WORDS = 8
COPY_SHARE = 0.9
COPY_MIN_SHINGLES = 25


def shingles(text: str) -> set[int]:
    _work(text)
    words = re.findall(r"[^\W_]+", fold(text or ""))
    if _WORK_BUDGET.get() is None:
        return {hash(" ".join(words[i:i + COPY_WORDS])) for i in range(len(words) - COPY_WORDS + 1)}
    result = set()
    for i in range(len(words) - COPY_WORDS + 1):
        _work(COPY_WORDS)
        result.add(hash(" ".join(words[i:i + COPY_WORDS])))
    return result


# Records about an admin-only document (2026-10-12, third audit), checked with the copy rule after
# every document is classified:
#   page-of-admin-document: the record is a hosted page or a derivative of one: its id or slug, a
#     URL among its page fields, or a source path in its frontmatter names an admin-only document;
#   describes-admin-document: its title, summary, body or other frontmatter links an admin-only
#     document (path, file name, distinctive slug, hosted-page slug), quotes its distinctive title,
#     or speaks of an admin-only document ("into one admin-only doc", "(admin-only frontmatter)").
# An admin-only document is named by its path, its file stem, the stem without a date prefix, its
# id or slug field, and the last part of a URL in its own page fields. Bare names must be distinctive
# (``distinctive_slug``) and must not also be the file stem of a document that stays on the map; a
# full path or an explicit page field always counts. A title counts when it has three or more words and 20 or more characters
# and no shown document carries the same title.
PAGE_RULE = "page-of-admin-document"
DESCRIBES_RULE = "describes-admin-document"
PAGE_FIELD = _lazy(r"^(?:id|slug|url|urls|page|pages|hosted|published|canonical|scroll|artifact|source|sources|"
                        r"derived_from|builds_on|based_on|[a-z]+_url|hosted_[a-z_]+|published_[a-z_]+|source_[a-z_]+)$",
                        re.I)
OWN_PAGE_FIELD = _lazy(r"^(?:url|urls|page|hosted|published|[a-z]+_url|hosted_[a-z_]+|published_[a-z_]+)$", re.I)
PAGE_LINK = _lazy(r"https?://[^\s\"'<>)\]`|]+")
DATE_PREFIX = _lazy(r"^\d{4}-\d{2}-\d{2}-")
REFERENCE_TOKEN = _lazy(r"[\w.-]+")
PATH_TOKEN = _lazy(r"[\w./-]+")
DOC_NOUN = r"(?:docs?|documents?|artifacts?|files?|lists?|memos?|briefings?|overviews?|pages?|versions?|drafts?|decks?|papers?|reports?)"
ADMIN_ONLY_NAMED = _lazy(
    r"\badmin[- ]only\s+" + DOC_NOUN + r"\b|\b" + DOC_NOUN + r"\b[^.\n]{0,40}\(\s*admin[- ]only\b|"
    r"\b(?:marked|saved|kept|flagged|filed|committed)\b[^.\n]{0,60}\badmin[- ]only\b|"
    r"\badmin[- ]only\s+frontmatter\b", re.I)
TITLE_QUOTE_WORDS, TITLE_QUOTE_CHARS = 3, 20


def reference_name(value: str) -> str:
    """A path, file name or URL reduced to its last part, lower case, without .md or .html."""
    value = value.strip().rstrip(".,;:!?)]'\"`").split("#", 1)[0].split("?", 1)[0]
    value = unquote(value)
    return re.sub(r"\.(?:md|html?)$", "", value.rstrip("/").rsplit("/", 1)[-1], flags=re.I).lower()


def title_key(text: str) -> str:
    return " ".join(re.findall(r"[^\W_]+", fold.__wrapped__(text or "")))  # uncached: whole documents


class AdminReferences:
    """Names, paths and titles of the admin-only documents, and the check against one record."""

    def __init__(self, admin_docs, kept_docs):
        self.paths: set[str] = set()
        self.page_names: set[str] = set()
        self.names: set[str] = set()
        self.titles: set[str] = set()
        candidate_names, candidate_titles = set(), set()
        for rel, fm, title in admin_docs:
            self.paths.update({rel.lower(), rel.lower().removesuffix(".md")})
            stem = Path(rel).stem.lower()
            names = {stem, DATE_PREFIX.sub("", stem)}
            for key in ("id", "slug"):
                if isinstance(fm.get(key), str):
                    names.add(reference_name(fm[key]))
            for key, value in fm.items():
                if OWN_PAGE_FIELD.match(str(key)):
                    names.update(reference_name(link) for text in strings_in(value) for link in PAGE_LINK.findall(text))
            # Explicit page metadata is a direct source reference even for a short slug or
            # when its derivative uses the same stem. Only prose references need ambiguity guards.
            self.page_names.update(n for n in names if n)
            candidate_names.update(n for n in names if distinctive_slug(n))
            key = title_key(title)
            if len(key.split()) >= TITLE_QUOTE_WORDS and len(key) >= TITLE_QUOTE_CHARS:
                candidate_titles.add(key)
        # An already identified page of a private source cannot make that source's names
        # ambiguous. Only independently eligible records may preserve shared vocabulary.
        independent_docs = [doc for doc in kept_docs if not self.page(doc.get("fm") or {})]
        kept_stems = {s for doc in independent_docs for s in (Path(doc["rel"]).stem.lower(),
                                                       DATE_PREFIX.sub("", Path(doc["rel"]).stem.lower()))}
        kept_titles = {title_key(doc.get("title") or "") for doc in independent_docs}
        self.names = candidate_names - kept_stems
        self.titles = candidate_titles - kept_titles
        self.digest = hashlib.sha256("\n".join(sorted(self.paths) + ["--"] + sorted(self.page_names) + ["--"] + sorted(self.names) + ["--"]
                                               + sorted(self.titles)).encode()).hexdigest()

    def _names_value(self, value: str) -> bool:
        value = value.strip()
        path = value.removeprefix("memory/").lower().rstrip("/")
        return path in self.paths or reference_name(value) in self.page_names

    def page(self, fm: dict) -> bool:
        for key, value in fm.items():
            if not PAGE_FIELD.match(str(key)):
                continue
            for text in strings_in(value):
                links = PAGE_LINK.findall(text)
                if any(reference_name(link) in self.page_names for link in links):
                    return True
                if not links and len(text) <= 300 and self._names_value(text):
                    return True
        return False

    def describes(self, title: str, summary: str, body: str, fm: dict) -> bool:
        text = "\n".join([title or "", summary or "", body or ""] + [s for v in fm.values() for s in strings_in(v)])
        _work(text)
        if any(reference_name(link) in self.page_names for link in PAGE_LINK.findall(text)):
            return True
        for match in PATH_TOKEN.finditer(text):
            token = match.group().strip("./").removeprefix("memory/").lower()
            if "/" in token and (token in self.paths or token.removesuffix(".md") in self.paths):
                return True
        for match in REFERENCE_TOKEN.finditer(text):
            if text[match.end():match.end() + 1] == "/" or text[max(0, match.start() - 1):match.start()] == "~":
                continue  # a folder, or a home-relative name
            if reference_name(match.group()) in self.names:
                return True
        if self.titles:
            words = " " + title_key(text) + " "
            for key in self.titles:
                _work(words)
                if " " + key + " " in words:
                    return True
        return bool(ADMIN_ONLY_NAMED.search(text))


def admin_shingles(admin_docs) -> dict[int, object]:
    """Word-gram -> the admin-only document holding it (an int), or a tuple when several do."""
    index: dict[int, object] = {}
    for k, (_rel, _fm, _title, body, _sha) in enumerate(admin_docs):
        for gram in shingles(body):
            held = index.get(gram)
            if held is None:
                index[gram] = k
            elif held != k and (isinstance(held, int) or k not in held):
                index[gram] = (held, k) if isinstance(held, int) else held + (k,)
    return index


def copy_of_admin(body: str, index: dict[int, object]) -> bool:
    grams = shingles(body)
    if len(grams) < COPY_MIN_SHINGLES or not index:
        return False
    inside: Counter = Counter()
    for gram in grams:
        held = index.get(gram)
        if held is None:
            continue
        inside.update((held,) if isinstance(held, int) else held)
    return bool(inside) and max(inside.values()) >= COPY_SHARE * len(grams)


def derivative_rule(doc: dict, references: AdminReferences, index: dict[int, object]) -> str:
    """copy-, page- or describes-admin-document for one parsed document, or ""."""
    _work(doc["body"])
    fm = doc.get("fm") or {}
    if copy_of_admin(doc["body"], index):
        return COPY_RULE
    if references.page(fm):
        return PAGE_RULE
    summary = doc.get("summary")
    if summary is None:
        summary = strip_memory_paths(summary_for(fm, doc["body"]))
    return DESCRIBES_RULE if references.describes(doc.get("title"), summary, doc["body"], fm) else ""


def derivatives(admin_docs, docs, known=None, released=frozenset(), learn=None, shields=None) -> dict[str, tuple[str | None, str]]:
    """rel -> (copy-, page- or describes-admin-document or None, key) for ``docs`` (dicts of rel, fm,
    title, summary, body) against ``admin_docs`` ((rel, fm, title, body, sha256)). Names are recomputed
    after each removal, so a derivative held in one pass shields no name in the next; an unchanged key
    (the admin set and its names) ends the run. ``known(rel, key)`` returns a kept verdict or None,
    ``learn`` hears every one; ``released`` documents stay shown; only ``shields`` make a name ambiguous."""
    admin_refs = [(rel, fm, title) for rel, fm, title, _body, _sha in admin_docs]
    admin_hashes = [f"{rel}\t{sha}" for rel, _fm, _title, _body, sha in admin_docs]
    found: dict[str, tuple[str | None, str]] = {}
    index = None
    candidates, key = list(docs), None
    while True:
        if (budget := _WORK_BUDGET.get()) is not None:
            budget.charge("passes")
        for rel, _fm, title in admin_refs:
            _work(rel)
            _work(title or "")
        for doc in candidates:
            _work(doc["rel"])
            _work(doc.get("title") or "")
        references = AdminReferences(admin_refs, [doc for doc in candidates if not shields or shields(doc)])
        last, key = key, hashlib.sha256("\n".join(admin_hashes + [references.digest]).encode()).hexdigest()
        if key == last:
            return found
        kept = []
        for doc in candidates:
            rule = known(doc["rel"], key) if known else None
            fresh = rule is None
            if fresh:
                if index is None:
                    index = admin_shingles(admin_docs)
                rule = derivative_rule(doc, references, index) or (
                    derivative_rule(doc["spelled"], references, index) if doc.get("spelled") else "")
            if learn:
                learn(doc["rel"], key, rule, fresh)
            found[doc["rel"]] = (rule or None, key)
            if not rule or doc["rel"] in released:
                kept.append(doc)
        if len(kept) == len(candidates):
            return found
        candidates = kept


# The exporter's curation (inventory, captures, noise), copied: a document off the members map never
# makes an admin name ambiguous there, so it does not here. test_held.py fails when they drift apart.
SKIP_DIRS = {"notes", "scratch", "identity", "onboarding", "diagnostics", "analytics",
             "todos", "lifecycle", "comments", "conversations", "dreams"}
SKIP_NAMES = {"index.md", "readme.md", "memory.md"}
PEOPLE_DIRS = {"people", "participants"}
GENERATED_FILE = _lazy(r"(?:^|/)artifacts/(?:[^/]+/)*[^/]*-session-dashboard\.md$"
                       r"|(?:^|/)sessions/(?:[^/]+/)*\d{2}-[^/-]+-session\.md$", re.I)
GENERATED_KINDS = {"ripcord"}
NOISE_SUBJECT = _lazy(r"^(?:wrap: )?ripcord\b|\b(?:raw (?:meeting|call) transcript|test handoff|delete me|page withdrawn)\b", re.I)


def noise_rule(title, fm, rel):
    # Imported corpora are raw source material, separate from the organization's work.
    parts = Path(rel.removeprefix("memory/")).parts
    if parts and parts[0] == "corpora":
        return "raw-corpus"
    if NOISE_SUBJECT.search(title) or {str(fm.get(key) or "").lower() for key in ("type", "kind")} & {
            "raw-transcript", "raw_transcript", "interruption", "session-interruption"}:
        return "raw-capture-or-placeholder"
    return None


def on_map(doc: dict) -> bool:
    """Whether the members map shows a document its rules leave shown (export.py inventory and parse)."""
    from .eligibility import is_internal_event

    rel, fm = doc["rel"], doc.get("fm") or {}
    parts, name = rel.split("/"), rel.rsplit("/", 1)[-1].lower()
    kinds = {str(fm.get(key) or "").strip().lower() for key in ("kind", "type")}
    return not (any(part.startswith(".") for part in parts) or any(part in PEOPLE_DIRS for part in parts[:-1])
                or (len(parts) > 1 and parts[0] in SKIP_DIRS) or name in SKIP_NAMES or name.startswith("waitlist")
                or GENERATED_FILE.search(rel) or kinds & GENERATED_KINDS or noise_rule(doc["title"], fm, rel)
                or is_internal_event("memory/" + rel, fm.get("type") if isinstance(fm.get("type"), str) else None))


# Each rule's names, so a verdict read back from the cache keeps its class.
RULE_CLASS = {**{name: 2 for name, _pattern in PAPERWORK_RULES}, "personnel-or-equity": 3, "raw-transcript": 4,
              "valuation-or-dilution": 5, "fundraising-figures": 5, "restricted-audience": 6,
              "restricted-marking": 6, "not-for-sharing": 6, "personal-capture": 7, "access-credential": 7,
              "contract-lifecycle": 7, "private-purpose": 7, "personnel-change": 8, "investor-outcome": 8,
              "interpersonal-conflict": 8, COPY_RULE: 9, PAGE_RULE: 9, DESCRIBES_RULE: 9}


# -- Verdicts over a memory tree, and their cache -----------------------------------------------
class Verdicts:
    """``held``: memory-relative path -> "admin" or the rule that holds it; ``computed``: the paths
    classified in this call rather than read from the cache; ``epoch``: holds_epoch over ``held``."""

    __slots__ = ("held", "computed", "documents", "epoch")

    def __init__(self, held: Mapping[str, str], computed: frozenset[str], documents: int, epoch: str):
        self.held, self.computed, self.documents, self.epoch = held, computed, documents, epoch


def cache_path(memory_root: Path) -> Path:
    """This user's private hint for one memory, beside its shadow counts and lifecycle state."""
    key = hashlib.sha256(str(Path(memory_root).resolve()).encode("utf-8")).hexdigest()[:16]
    return Path.home() / ".egregore" / "runtime" / "held" / f"{key}.json"


def _documents(root: Path):
    """(path as named, path it resolves to, its stat) for every Markdown document under ``root``, as ``os.walk``
    lists them: dot names skipped, a folder link never followed, a file link only to a regular file inside ``root``.
    One ``lstat`` per file and no ``Path`` per entry: this walk is every Runtime process's freshness check."""
    base = str(root)
    folders = [""]
    while folders:
        folder = folders.pop()
        try:
            with os.scandir(os.path.join(base, folder) if folder else base) as listing:
                found = sorted(listing, key=lambda entry: entry.name)
        except OSError:
            continue
        for entry in found:
            name = entry.name
            if name.startswith("."):
                continue
            rel = f"{folder}/{name}" if folder else name
            try:
                is_folder = entry.is_dir()
            except OSError:
                is_folder = False
            if is_folder:
                if not entry.is_symlink():
                    folders.append(rel)
                continue
            if not name.lower().endswith(".md"):
                continue
            try:
                info, target = entry.stat(follow_symlinks=False), rel
                if stat.S_ISLNK(info.st_mode):
                    resolved = Path(entry.path).resolve(strict=True)
                    if not resolved.is_relative_to(root):
                        continue
                    info, target = resolved.stat(), resolved.relative_to(root).as_posix()
            except (OSError, RuntimeError, ValueError):
                continue
            if stat.S_ISREG(info.st_mode):
                yield rel, target, info


def _read_cache(path: Path) -> dict:
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
        entries = data.get("entries") if data.get("version") == 1 else None
    except (OSError, ValueError, AttributeError):
        return {}
    return entries if isinstance(entries, dict) else {}


def _write_private(path: Path, payload: dict) -> None:
    path = Path(path)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, separators=(",", ":"))
        temporary.replace(path)
    except OSError:
        pass  # A hint only: no verdict depends on it being written.


def _write_cache(path: Path, entries: dict) -> None:
    _write_private(path, {"version": 1, "entries": entries})


def _verdict(value) -> str | None:
    """A cached verdict, or None when the hint is not one this module could have written."""
    return value if isinstance(value, str) and (not value or value in RULE_CLASS) else None


def _prefixes(release: Iterable[str]) -> tuple[str, ...]:
    """``access.release`` paths and folders, relative to memory ("" is all of it)."""
    return tuple(sorted({item.strip().strip("/").removeprefix("memory").strip("/") for item in release if isinstance(item, str)}))


class Tree:
    """One memory tree, as walked or as committed: class 1 and the rules per document, then the admin
    derivatives among the documents still shown, to the exporter's fixpoint. ``entries``: rel ->
    (target, sha256, verdict) before releases; ``held``: after them (a rule verdict is lifted when both
    spellings are released, class 1 never); ``computed``: classified now, not taken from ``cache``."""

    def __init__(self, documents: Iterable[tuple[str, str, bytes]], *, release: Iterable[str] = (),
                 cache: Path | None = None):
        prefixes = _prefixes(release)

        def lifted(rel: str) -> bool:
            return any(not p or rel == p or rel.startswith(p + "/") for p in prefixes)

        docs = sorted((rel, target, hashlib.sha256(raw).hexdigest(), raw.decode("utf-8", errors="replace"))
                      for rel, target, raw in documents)
        admin_set = hashlib.sha256("\n".join(f"{rel}\t{sha}" for rel, _, sha, text in docs
                                             if document_is_admin(text)).encode()).hexdigest()
        release_digest = hashlib.sha256(json.dumps(list(prefixes)).encode()).hexdigest()
        stored = _read_cache(cache) if cache is not None else {}
        entries: dict[str, str] = {}
        computed: set[str] = set()
        self.entries: dict[str, tuple[str, str, str]] = {}
        self.held: dict[str, str] = {}
        self.documents = len(docs)
        self.listed = tuple((rel, target) for rel, target, *_ in docs)  # (path as named, path it reads as)
        self._admin_docs: list = []
        self._shown: list[dict] = []
        free: set[str] = set()
        for rel, target, sha, text in docs:
            _work(text)
            if document_is_admin(text):
                doc = _parse(rel, text, summary=False)
                self._admin_docs.append((rel, doc["fm"], doc["title"], doc["body"], sha))
                self.entries[rel] = (target, sha, "admin")
                self.held[rel] = "admin"
                continue
            key = hashlib.sha256(json.dumps([rel, target, sha, HELD_RULES_VERSION, admin_set,
                                             release_digest]).encode()).hexdigest()
            verdict = _verdict(stored.get(key))
            doc = None
            if verdict is None:
                doc = _parse(rel, text)
                verdict = (document_rule(rel, text, doc["fm"], doc["body"], doc["title"], doc["summary"])
                           or (target != rel and _rule(target, text)) or "")
                computed.add(rel)
            entries[key] = verdict
            self.entries[rel] = (target, sha, verdict)
            if lifted(rel) and lifted(target):
                free.add(rel)
            elif verdict:
                self.held[rel] = verdict
                continue
            doc = doc or _parse(rel, text, summary=False)
            spelled = None if target == rel else {**doc, "rel": target, "title": title_for(doc["fm"], doc["body"], target)}
            self._shown.append({**doc, "target": target, "sha": sha, "spelled": spelled})

        def name(doc: dict, key: str) -> str:
            return hashlib.sha256(json.dumps(["derived", doc["rel"], doc["target"], doc["sha"], HELD_RULES_VERSION,
                                              key]).encode()).hexdigest()

        shown = {doc["rel"]: doc for doc in self._shown}

        def learn(rel: str, key: str, rule: str, fresh: bool) -> None:
            entries[name(shown[rel], key)] = rule
            if fresh:
                computed.add(rel)

        found = derivatives(self._admin_docs, self._shown, lambda rel, key: _verdict(stored.get(name(shown[rel], key))),
                            free, learn, on_map)
        for rel, (rule, _key) in found.items():
            if rule and not self.entries[rel][2]:
                self.entries[rel] = (*self.entries[rel][:2], rule)
                if rel not in free:
                    self.held[rel] = rule
        self._judge, self.renew = None, None
        # What a later document is judged against: the names of the documents still shown, not their text.
        self._shown = [{"rel": doc["rel"], "fm": doc["fm"], "title": doc["title"]}
                       for doc in self._shown if doc["rel"] not in self.held]
        self.computed = frozenset(computed)
        if cache is not None and (computed or len(entries) != len(stored)):
            _write_cache(cache, entries)

    def _derived(self, doc: dict, read_as: tuple[str, ...] = ()) -> str:
        """Whether ``doc`` derives from this tree's admin-only set. ``read_as`` names the spellings whose bytes
        ``doc`` is when they differ from this tree's: their copies here shield no name, and the document as read
        shields as the exporter would read it, so a newer copy cannot hide the bytes a caller read."""
        admins = [(r, fm, title) for r, fm, title, _b, _s in self._admin_docs]
        if self._judge is None:
            self._judge = (AdminReferences(admins, [shown for shown in self._shown if on_map(shown)]),
                           admin_shingles(self._admin_docs))
        references, index = self._judge
        if read_as:
            kept = [shown for shown in self._shown if shown["rel"] not in read_as] + [
                {"rel": name, "fm": doc["fm"], "title": title_for(doc["fm"], doc["body"], name)} for name in read_as]
            references = AdminReferences(admins, [shown for shown in kept if on_map(shown)])
        return derivative_rule(doc, references, index)

    def _entry(self, rel: str) -> tuple[str, str, str] | None:
        return self.entries.get(rel)

    def _spelled(self, entry: tuple[str, str, str], target: str | None) -> bool:
        """Whether ``target`` is the file this entry resolved to (None: as named)."""
        return target in (None, entry[0])

    walk = ""  # the digest of the walk this tree answers for, when it is one
    _judged = None

    def verdict(self, rel: str, sha: str, target: str | None = None) -> str | None:
        """The verdict this tree holds for these bytes (by sha256) at ``rel``, "" when shown; None when it holds none
        for them: changed, never walked, or read through another spelling. Class 1 is the caller's to read."""
        entry = self._entry(rel)
        return entry[2] if entry is not None and entry[1] == sha and self._spelled(entry, target) else None

    def _remembered(self) -> "_Judged":
        if self._judged is None:
            self._judged = _Judged(None, self.walk)
        return self._judged

    def known(self, rel: str, sha: str, target: str | None = None) -> tuple[int, ...] | None:
        """The classes this tree already judged for these bytes at ``rel`` (not class 1), without renewing or
        deriving: its verdict, or a judgement kept for bytes it holds none for. None when neither exists."""
        verdict = self.verdict(rel, sha, target)
        if verdict is not None:
            return (RULE_CLASS[verdict],) if verdict in RULE_CLASS else ()
        return self._remembered().get(rel, target, sha)

    def classes(self, rel: str, raw: bytes | None, target: str | None = None, renew: bool = True) -> tuple[int, ...]:
        """The class of one document as read now: its verdict here while its bytes are unchanged. A document
        walked since, or changed, renews a walked tree first; otherwise its rules under both spellings and
        a derivative check against this tree's admin-only set decide."""
        if raw is None:
            return ()
        text = raw.decode("utf-8", errors="replace")
        if document_is_admin(text):  # class 1 is read from the bytes on every call
            return (1,)
        entry, sha = self._entry(rel), hashlib.sha256(raw).hexdigest()
        if entry is not None and entry[1] == sha and self._spelled(entry, target):
            return (RULE_CLASS[entry[2]],) if entry[2] in RULE_CLASS else ()
        linked = self._entry(target) if entry is None and target not in (None, rel) else None
        if linked is not None and linked[1] == sha:
            verdict = linked[2] if linked[2] in RULE_CLASS else ""
            return text_classes(text, rel) or ((RULE_CLASS[verdict],) if verdict else ()) or (
                (9,) if self._derived(_parse(rel, text)) else ())
        walked = rel.lower().endswith(".md") and not any(part.startswith(".") for part in rel.split("/"))
        if renew and self.renew and (entry is not None or walked):
            return self.renew().classes(rel, raw, target, renew=False)
        kept = self._remembered().get(rel, target, sha)  # judged here before: a function of this walk and these bytes
        if kept is not None:
            return kept
        found = text_classes(text, rel) or (text_classes(text, target) if target not in (None, rel) else ())
        spellings = (rel,) if target in (None, rel) else (rel, target)
        read_as = spellings if walked else ()  # these bytes stand in for this tree's copy of the document
        found = found or ((9,) if any(self._derived(_parse(name, text), read_as) for name in spellings) else ())
        self._remembered().put(rel, target, sha, found)
        return found


_TREES: dict[tuple, tuple[float, str, Tree | None]] = {}
FRESH_SECONDS = 2.0  # a walked tree answers this long before memory is walked again
INDEX_VERSION = 1
# A file changed this shortly before a walk can change again within its file system's timestamp granularity (a
# second or two on some, a coarse clock tick on others) and keep its stat. Before an index that saw such a file is
# trusted the file is hashed again, as git treats a racily clean index entry.
RACY_NS = 2_000_000_000
TURN_SECONDS = 120.0  # how long a build waits for another process building the same memory, then builds too
_now = time.time_ns


_ROOTS: dict[str, tuple[float, Path]] = {}


def _resolved(memory_root: Path) -> Path:
    """The memory root resolved, again after FRESH_SECONDS: a policy check asks for it on every read."""
    name, now = str(memory_root), time.monotonic()
    seen = _ROOTS.get(name)
    if seen is None or now - seen[0] >= FRESH_SECONDS:
        seen = _ROOTS[name] = (now, Path(memory_root).resolve())
    return seen[1]


def _remember(key: tuple, digest: str, build, walked: float) -> Tree | None:
    seen = _TREES.get(key)
    if seen is None or seen[1] != digest:
        built = build()
        if built is None:
            return None
        while len(_TREES) >= 4:
            _TREES.pop(next(iter(_TREES)))
        seen = (walked, digest, built)
    _TREES[key] = (walked, digest, seen[2])
    return seen[2]


def _hashed(rel: str) -> str:
    """A path as the verdict index names it: like the hint, the index names no path."""
    return hashlib.sha256(b"held-index\0" + rel.encode("utf-8", "surrogateescape")).hexdigest()[:32]


def index_path(memory_root: Path) -> Path:
    """This user's verdict index for one memory, beside its hint: hashed paths, content digests and verdicts."""
    hint = cache_path(memory_root)
    return hint.with_name(hint.stem + ".index.json")


def _judged_path(memory_root: Path) -> Path:
    hint = cache_path(memory_root)
    return hint.with_name(hint.stem + ".judged.json")


class _Judged:
    """Classes a tree judged for bytes its walk holds no verdict for (a document in a dot folder, an unwalked
    spelling, bytes changed since the walk), by hashed spellings and content digest. They hold for that walk
    alone; with a ``path`` (this user's index folder) they are kept for later processes on the same walk."""

    def __init__(self, path: Path | None, walk: str):
        self.path, self.walk, self.entries, self.added = path, walk, {}, False
        self.loaded = path is None or not walk

    @staticmethod
    def _key(rel: str, target: str | None, sha: str) -> str:
        return f"{_hashed(rel)}:{_hashed(target or rel)}:{sha}"

    def _stored(self) -> dict:
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
            entries = data.get("entries") if data.get("version") == 1 and data.get("walk") == self.walk else None
        except (OSError, ValueError, AttributeError):
            return {}
        return {key: tuple(value) for key, value in (entries.items() if isinstance(entries, dict) else ())
                if isinstance(value, list) and all(type(number) is int and 2 <= number <= 9 for number in value)}

    def get(self, rel: str, target: str | None, sha: str) -> tuple[int, ...] | None:
        if not self.loaded:
            self.loaded = True
            self.entries = {**self._stored(), **self.entries}
        return self.entries.get(self._key(rel, target, sha))

    def put(self, rel: str, target: str | None, sha: str, found: tuple[int, ...]) -> None:
        self.entries[self._key(rel, target, sha)] = tuple(found)
        if self.path is not None and self.walk and not self.added:
            self.added = True
            atexit.register(self.save)

    def save(self) -> None:
        _write_private(self.path, {"version": 1, "walk": self.walk,
                                   "entries": {key: list(value) for key, value in {**self._stored(), **self.entries}.items()}})


class _Index(Tree):
    """A walk this user already built, read back from the verdict index: each document's verdict by hashed path
    and content sha256, nothing parsed. Bytes it never judged derive against the full tree of the same walk,
    built on first need (``full``)."""

    def __init__(self, entries: dict, documents: int, full, pairs: tuple = (), release: tuple[str, ...] = ()):
        self.entries, self.documents, self.computed = entries, documents, frozenset()
        self._build, self._full, self._judge, self.renew = full, None, None, None
        self._release, self._held, self.listed = release, None, pairs

    def _entry(self, rel: str):
        return self.entries.get(_hashed(rel))

    def _spelled(self, entry, target) -> bool:
        return target is None or entry[0] == _hashed(target)

    def full(self) -> Tree:
        if self._full is None:
            self._full = self._build()
        return self._full

    @property
    def held(self) -> dict[str, str]:
        """``Tree.held`` from the index and the walk's names, nothing parsed: class 1 always, a rule or
        derivative verdict unless both spellings are released."""
        if self._held is None:
            def lifted(rel: str) -> bool:
                return any(not p or rel == p or rel.startswith(p + "/") for p in self._release)
            self._held = {rel: entry[2] for rel, target in self.listed if (entry := self._entry(rel)) and entry[2]
                          and (entry[2] == "admin" or not (lifted(rel) and lifted(target)))}
        return self._held

    def _derived(self, doc: dict, read_as: tuple[str, ...] = ()) -> str:
        return self.full()._derived(doc, read_as)


def _write_index(root: Path, digest: str, listed: int, built: Tree) -> None:
    entries = {_hashed(rel): [_hashed(target), sha, verdict] for rel, (target, sha, verdict) in built.entries.items()}
    _write_private(index_path(root), {"version": INDEX_VERSION, "digest": digest, "listed_ns": listed,
                                      "documents": built.documents, "entries": entries})


def _read_index(root: Path, digest: str, listing: list, listed: int, full, release: tuple[str, ...] = ()) -> _Index | None:
    """The index of exactly this walk, or None. A file changed within RACY_NS before the walk the index saw is
    hashed again first; once every such file has aged past that window the index is re-dated, so later walks
    hash nothing."""
    try:
        data = json.loads(index_path(root).read_text(encoding="utf-8"))
        if data.get("version") != INDEX_VERSION or data.get("digest") != digest:
            return None
        stored, documents, seen = data["entries"], data["documents"], data["listed_ns"]
        if not isinstance(stored, dict) or type(documents) is not int or type(seen) is not int:
            return None
        if documents != len(listing) or len(stored) != len(listing):
            return None  # a build that could not read every document it listed answers for no walk
        entries = {}
        for name, value in stored.items():
            if not (isinstance(value, list) and len(value) == 3 and all(isinstance(part, str) for part in value)
                    and (value[2] == "admin" or _verdict(value[2]) is not None)):
                return None
            entries[name] = tuple(value)
        racy = [(rel, target, ctime) for rel, target, _size, _mtime, ctime, _inode in listing if ctime >= seen - RACY_NS]
        for rel, target, _ctime in racy:
            entry = entries.get(_hashed(rel))
            if entry is None or entry[1] != hashlib.sha256((root / target).read_bytes()).hexdigest():
                return None
    except (OSError, ValueError, AttributeError, KeyError, TypeError):
        return None
    if racy and all(ctime < listed - RACY_NS for *_, ctime in racy):
        _write_private(index_path(root), {**data, "listed_ns": listed})
    return _Index(entries, documents, full, tuple((rel, target) for rel, target, *_ in listing), release)


@contextmanager
def _turn(root: Path, wait: float = TURN_SECONDS):
    """This memory's build turn: a private lock beside its index, waited for up to ``wait`` seconds. Past that, or
    without a lock, the build goes ahead: a stuck builder costs time, never a verdict."""
    descriptor = None
    try:
        lock = index_path(root).with_suffix(".lock")
        lock.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        descriptor = os.open(lock, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        deadline = time.monotonic() + wait
        while True:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    break
                time.sleep(0.05)
    except OSError:
        pass
    try:
        yield
    finally:
        if descriptor is not None:
            os.close(descriptor)


def tree(memory_root: Path, release: Iterable[str] = (), *, trust_cache: bool = False, fresh: bool = False,
         build: bool = True) -> Tree | None:
    """Memory as walked within FRESH_SECONDS (now, when ``fresh``); built again only when a document's
    size, times, inode or target changed. With ``trust_cache`` (the operator's own reads and slot) a walk this
    user already built is read back from the verdict index, and builds of one memory take turns, so one memory
    state is built once per machine. ``build=False`` returns None instead of building."""
    return current(memory_root, release, trust_cache=trust_cache, fresh=fresh, build=build)[0]


def current(memory_root: Path, release: Iterable[str] = (), *, trust_cache: bool = False, fresh: bool = False,
            build: bool = True) -> tuple[Tree | None, str]:
    """``tree``, and the digest of the walk it answers for: the walk in effect now."""
    root, release = _resolved(memory_root), _prefixes(release)
    key = ("tree", str(root), release, trust_cache)
    for seen in (_TREES.get(key), None if build else _TREES.get(("unbuilt", *key))):
        if seen is not None and not fresh and time.monotonic() - seen[0] < FRESH_SECONDS:
            return seen[2], seen[1]
    walked, listed = time.monotonic(), _now()
    listing = sorted((rel, target, info.st_size, info.st_mtime_ns, info.st_ctime_ns, info.st_ino)
                     for rel, target, info in _documents(root))
    digest = hashlib.sha256(json.dumps([INDEX_VERSION, HELD_RULES_VERSION, release, listing]).encode()).hexdigest()

    def documents():
        for rel, target, *_ in listing:
            try:
                yield rel, target, (root / target).read_bytes()
            except OSError:
                continue

    def full() -> Tree:
        return Tree(documents(), release=release, cache=cache_path(root) if trust_cache else None)

    def make() -> Tree | None:
        if not trust_cache:
            found = full() if build else None
        elif (found := _read_index(root, digest, listing, listed, full, release)) is None and build:
            with _turn(root):
                found = _read_index(root, digest, listing, listed, full, release)  # built meanwhile by the turn before
                if found is None:
                    found = full()
                    if found.documents == len(listing):  # one it could not read leaves no index behind
                        _write_index(root, digest, listed, found)
        if found is not None:
            found.renew = lambda: tree(root, release, trust_cache=trust_cache, fresh=True)
            found.walk = digest
            found._judged = _Judged(_judged_path(root) if trust_cache else None, digest)
        return found

    found = _remember(key, digest, make, walked)
    if found is None:  # nothing to read back for this walk: calls that would not build reuse it
        _TREES[("unbuilt", *key)] = (walked, digest, None)
    return found, digest


LINK_HOPS = 40  # the kernel's limit: a longer chain, or a cycle, resolves to nothing


def committed_target(memory, name: str) -> str | None:
    """The committed regular file ``name`` reads as, resolved part by part as the file system resolves a path: a
    link anywhere along it (a chain, a folder link, a target in a dot folder or under another name) is followed.
    None for a cycle, an absolute target, a target above memory, or anything but a committed file at the end."""
    resolved, pending, hops = [], name.split("/"), 0
    budget = getattr(memory, "budget", None)
    while pending:
        if budget is not None:
            budget.remaining()
            budget.charge("work", 1 + len(pending[0]))
        part = pending.pop(0)
        if part in ("", "."):
            continue
        if part == "..":
            if not resolved:
                return None
            resolved.pop()
            continue
        resolved.append(part)
        entry = memory.entries.get("/".join(resolved))
        if entry is not None and entry[0] == "120000":
            hops += 1
            link = memory.read("/".join(resolved)).decode("utf-8", "surrogateescape")
            if hops > (budget.limits.link_hops if budget is not None else LINK_HOPS) or not link or link.startswith("/"):
                return None
            resolved.pop()
            pending = link.split("/") + pending
    entry = memory.entries.get("/".join(resolved))
    return "/".join(resolved) if entry is not None and entry[0] in {"100644", "100755"} else None


def committed_tree(memory, release: Iterable[str] = ()) -> Tree:
    """Memory as committed at one revision (an ``access.CommittedMemory``), never from a cache. A committed link
    reads as the file it resolves to, as the walk reads one on disk."""
    release = _prefixes(release)

    def build() -> Tree:
        names = {name: mode for name, (mode, _oid) in memory.entries.items() if mode in {"100644", "100755", "120000"}
                 and name.lower().endswith(".md") and not any(part.startswith(".") for part in name.split("/"))}
        memory.prefetch([name for name, (mode, _oid) in memory.entries.items() if mode == "120000"])
        found = {name: name if mode != "120000" else committed_target(memory, name) for name, mode in names.items()}
        found = {name: target for name, target in found.items() if target}
        memory.prefetch(sorted(set(found.values())))
        return Tree(((name, target, memory.read(target)) for name, target in sorted(found.items())), release=release)

    return _remember(("committed", str(Path(memory.root).resolve()), release), memory.revision, build, time.monotonic())


def _file_identity(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_nlink, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def _inventory_row(budget, rows, *row):
    data = json.dumps(row, ensure_ascii=True, separators=(",", ":"))
    budget.charge("inventory_bytes", len(data.encode()))
    rows.append(row)


def _bounded_target(root_fd, relative, budget, rows):
    """Read one spelling through owned directory descriptors; never follow an escape."""
    pending, resolved, directories, hops = relative.split("/"), [], [os.dup(root_fd)], 0
    try:
        while pending:
            budget.remaining()
            part = pending.pop(0)
            if part in ("", "."):
                continue
            if part == "..":
                if not resolved:
                    return None
                resolved.pop(); os.close(directories.pop())
                continue
            named = "/".join([*resolved, part])
            if len(os.fsencode(named)) > budget.limits.path_bytes:
                budget.fail()
            try:
                info = os.stat(part, dir_fd=directories[-1], follow_symlinks=False)
            except FileNotFoundError:
                _inventory_row(budget, rows, "absent-target", named)
                return None
            _inventory_row(budget, rows, "target", named, _file_identity(info))
            if stat.S_ISLNK(info.st_mode):
                hops += 1
                if hops > budget.limits.link_hops:
                    return None
                link = os.readlink(part, dir_fd=directories[-1])
                if len(os.fsencode(link)) > budget.limits.path_bytes:
                    budget.fail()
                _inventory_row(budget, rows, "link", named, link)
                if _file_identity(os.stat(part, dir_fd=directories[-1], follow_symlinks=False)) != _file_identity(info):
                    budget.fail()
                if not link or link.startswith("/"):
                    return None
                pending = link.split("/") + pending
                continue
            if stat.S_ISDIR(info.st_mode):
                if not pending:
                    return None
                descriptor = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directories[-1])
                if _file_identity(os.fstat(descriptor)) != _file_identity(info):
                    os.close(descriptor); budget.fail()
                resolved.append(part); directories.append(descriptor)
                continue
            if pending or not stat.S_ISREG(info.st_mode):
                return None
            if not info.st_mode & 0o444 or info.st_size > budget.limits.dependency_bytes:
                budget.fail()
            descriptor = os.open(part, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directories[-1])
            with os.fdopen(descriptor, "rb", buffering=0) as stream:
                before = os.fstat(stream.fileno())
                if _file_identity(before) != _file_identity(info):
                    budget.fail()
                budget.charge("total_bytes", before.st_size)
                data = stream.read(before.st_size + 1)
                budget.remaining()
                if len(data) != before.st_size or _file_identity(os.fstat(stream.fileno())) != _file_identity(before):
                    budget.fail()
            return named, data, _file_identity(info)
        return None
    finally:
        for descriptor in directories:
            os.close(descriptor)


def _bounded_working_source(root, budget):
    budget = _read_budget(budget)
    root = Path(root)
    if not root.is_absolute() or root != root.resolve(strict=True):
        budget.fail()
    root_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    rows, documents, identities = [], {}, {}
    root_identity = _file_identity(os.fstat(root_fd))

    def walk(directory, prefix):
        budget.remaining()
        before = os.fstat(directory)
        if not before.st_mode & 0o444 or not before.st_mode & 0o111:
            budget.fail()
        _inventory_row(budget, rows, "directory", prefix, _file_identity(before))
        names = []
        with os.scandir(directory) as entries:
            for entry in entries:
                budget.charge("entries")
                name = entry.name
                if len(os.fsencode(prefix + name)) > budget.limits.path_bytes:
                    budget.fail()
                names.append(name)
        for name in sorted(names):
            budget.remaining()
            relative = prefix + name
            if name.startswith("."):
                _inventory_row(budget, rows, "hidden", relative)
                continue
            info = os.stat(name, dir_fd=directory, follow_symlinks=False)
            _inventory_row(budget, rows, "entry", relative, _file_identity(info))
            if stat.S_ISDIR(info.st_mode):
                child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
                try:
                    if _file_identity(os.fstat(child)) != _file_identity(info):
                        budget.fail()
                    walk(child, relative + "/")
                finally:
                    os.close(child)
            elif name.lower().endswith(".md") and stat.S_IFMT(info.st_mode) in {stat.S_IFREG, stat.S_IFLNK}:
                if (selected := _bounded_target(root_fd, relative, budget, rows)) is not None:
                    if len(documents) >= budget.limits.documents:
                        budget.fail()
                    target, data, identity = selected
                    documents[relative] = (target, data)
                    identities[relative] = (_file_identity(info), identity)
                    _inventory_row(budget, rows, "content", relative, target, hashlib.sha256(data).hexdigest())
        if _file_identity(os.fstat(directory)) != _file_identity(before):
            budget.fail()

    try:
        walk(root_fd, "")
        budget.remaining()
        fingerprint = hashlib.sha256(json.dumps(rows, ensure_ascii=True, separators=(",", ":")).encode()).hexdigest()
        return root_identity, fingerprint, documents, identities
    except (OSError, ValueError, RuntimeError):
        budget.fail()
    finally:
        os.close(root_fd)


class _BoundedTree:
    __slots__ = ("root", "budget", "release", "rules", "source", "identity", "fingerprint", "documents", "identities", "tree")

    def __init__(self, root, release, budget, committed):
        self.root, self.budget, self.release, self.rules = Path(root), budget, tuple(release), HELD_RULES_VERSION
        self.source = committed
        if committed is None:
            self.identity, self.fingerprint, self.documents, self.identities = _bounded_working_source(self.root, budget)
        else:
            self.identity, self.fingerprint, self.documents, self.identities = committed.hold_documents()
        token = _WORK_BUDGET.set(budget)
        try:
            self.tree = Tree(((rel, target, raw) for rel, (target, raw) in self.documents.items()), release=release)
            budget.remaining()
        finally:
            _WORK_BUDGET.reset(token)

    def classes(self, relative, raw, target=None):
        self.budget.remaining()
        entry = self.documents.get(relative)
        if self.rules != HELD_RULES_VERSION or entry is None or entry != (target or relative, raw):
            self.budget.fail()
        # Exact captured entries only. The ordinary Tree renewal/derivation path
        # is deliberately unreachable, including for a caller's replacement bytes.
        if admin_class(raw):
            return (1,)
        found = self.tree.verdict(relative, hashlib.sha256(raw).hexdigest(), entry[0])
        if found is None:
            self.budget.fail()
        return (RULE_CLASS[found],) if found in RULE_CLASS else ()

    def recheck(self):
        self.budget.remaining()
        if self.rules != HELD_RULES_VERSION:
            self.budget.fail()
        if self.source is not None:
            self.source.recheck()
        else:
            identity, fingerprint, _docs, _identities = _bounded_working_source(self.root, self.budget)
            if identity != self.identity or fingerprint != self.fingerprint:
                self.budget.fail()


def bounded_tree(memory_root, release=(), *, budget, committed=None):
    """Complete bounded rule inputs; no cache, lock, shadow, renewal or writes."""
    budget = _read_budget(budget)
    try:
        if committed is not None:
            from .access import _BoundedCommittedMemory
            if type(committed) is not _BoundedCommittedMemory or committed.budget is not budget or committed.root != Path(memory_root):
                budget.fail()
        return _BoundedTree(memory_root, release, budget, committed)
    except (OSError, ValueError, RuntimeError):
        budget.fail()


def verdicts(memory_root: Path, *, admins: Iterable[str] = (), release: Iterable[str] = (),
             trust_cache: bool = False, cache: Path | None = None) -> Verdicts:
    """Classify every Markdown document under ``memory_root``.

    Class 1 is read from each file on every call. A rule verdict is cached under (path as named,
    resolved path, content sha256, rules version, admin-set digest, release digest), a derivative's
    under the digest of the admin-only set and its names instead of the last two; the cache is read
    only with ``trust_cache=True``: the operator's own reads and slot. ``release`` (memory paths)
    lifts a rule verdict, never ``admin: true``. A symlink inside memory is held when either its own
    path or its target is, as the predicate checks both spellings.
    """
    root = Path(memory_root).resolve()

    def documents():
        for rel, target, _info in _documents(root):
            try:
                yield rel, target, (root / target).read_bytes()
            except OSError:
                continue

    found = Tree(documents(), release=release, cache=cache if trust_cache else None)
    return Verdicts(found.held, found.computed, found.documents, holds_epoch(admins, held=found.held))


def holds_epoch(admins: Iterable[str], released: Iterable[str] = (), held: Mapping[str, str] | None = None) -> str:
    """Digest the rules version, the admin set, the releases and, when known, the held set (path -> class)."""
    payload: list = [HELD_RULES_VERSION, sorted({handle.strip().casefold() for handle in admins})]
    payload += [sorted(set(released))] if released else []
    if held is not None:
        payload.append(sorted(held.items()))
    return hashlib.sha256(json.dumps(payload, separators=(",", ":")).encode()).hexdigest()


# -- Redaction: held names leave no text a non-admin is handed --------------------------------------
class RedactionError(EgregoreRuntimeError):
    """A held name survived redaction, so nothing is handed over."""


_RUN_STOPS = frozenset("`'\"()[]<>{}|,;*~\u2018\u2019\u201c\u201d")
_RUN = _lazy(r"[^\s`'\"()\[\]<>{}|,;*~\u2018\u2019\u201c\u201d]+")
_WORD = _lazy(r"[^\W_]+")
# A run's segments split at / : = # ? & and trimmed of _ . ! at both ends: each name's last one is one.
_D = "\\s`'\"()\\[\\]<>{}|,;*~\u2018\u2019\u201c\u201d/:=#?&"
_PIECE = _lazy(r"[:=#?&]")
_SEGMENT = _lazy(f"[^{_D}_.!](?:[^{_D}]*[^{_D}_.!])?")
_ESCAPE = _lazy(r"%[0-9A-Fa-f]{2}")


def _run(text: str, start: int, end: int) -> tuple[int, int]:
    """The whole run (see ``_RUN``) around a segment."""
    while start and not (text[start - 1].isspace() or text[start - 1] in _RUN_STOPS):
        start -= 1
    while end < len(text) and not (text[end].isspace() or text[end] in _RUN_STOPS):
        end += 1
    return start, end


def _title_words(title: str) -> tuple[str, ...]:
    return tuple(word.casefold() for word in _WORD.findall(title))


def _spelled(names) -> re.Pattern | None:
    """Exact spellings, case aside, never inside a word or a dotted or hyphenated name; an
    underscore is a boundary, as Markdown emphasis wraps a path in it."""
    names = "|".join(map(re.escape, sorted(names, key=len, reverse=True)))
    return re.compile(rf"(?<![^\W_])(?<![.-])(?:{names})(?![^\W_])(?!-)", re.IGNORECASE) if names else None


def _strip(text: str, spans: list[tuple[int, int]]) -> str:
    kept, at = [], 0
    for start, end in spans:
        if start >= at:
            kept.append(text[at:start])
        at = max(at, end)
    return "".join(kept) + text[at:]


def describe(canonical: str, data: bytes) -> tuple[str, str, tuple[str, ...]]:
    """A document's title, its stable artifact id, and every id, slug or session id it declares."""
    text = data.decode("utf-8", "replace")
    try:
        fields, body = split_frontmatter(text)
    except ArtifactSchemaError:
        fields, body = {}, text
    title = next((str(fields[key]).strip() for key in ("title", "topic", "name") if fields.get(key)), "")
    if not title and (heading := re.search(r"^#\s+(.+?)\s*$", body, re.MULTILINE)):
        title = heading.group(1).strip()
    aliases = tuple(str(fields[key]).strip() for key in ("artifact_id", "id", "session_id", "slug")
                    if isinstance(fields.get(key), (str, int)))
    return title, canonical_artifact_id(text, canonical), aliases


class Redactor:
    """Spellings that name a held document, except those a shown document also answers to
    (``AdminReferences`` precedent): a shared file name narrows to its shortest folder path no
    shown path spells; a shared slug or title is ordinary vocabulary. An id is an identity: a held
    one stays held though a shown document declares it too or is named for it. A name no run can
    hold (a space or a quote in it) is matched by its exact spelling: a held document is found by
    its path, never by a name a shown one shares.

    ``held_docs``: (canonical path, title, artifact id, declared ids) per held document;
    ``shown_titles``: the shown documents' titles, or a function that reads them on first need
    (a held title found in a text)."""

    def __init__(self, held_docs: Iterable[tuple[str, str, str, tuple[str, ...]]], shown_paths: Iterable[str],
                 shown_titles: Iterable[str] | Callable[[], Iterable[str]]):
        shown_rel = [path.removeprefix("memory/").casefold() for path in shown_paths]
        stems = {rel.rsplit("/", 1)[-1].removesuffix(".md") for rel in shown_rel}
        stems |= {DATE_PREFIX.sub("", stem) for stem in stems}
        listed = "\n".join(shown_rel)

        def shared(name: str) -> bool:  # a shown path answers to this spelling too
            if _RUN.fullmatch(name):
                return any(other == name or other.endswith("/" + name) for other in shown_rel)
            return _spelled([name]).search(listed) is not None
        self.names: set[str] = set()
        self._titles: dict[str, set[tuple[str, ...]]] = {}
        self._shown_titles, self._kept, self._lasts = shown_titles, None, None
        for canonical, title, artifact_id, aliases in held_docs:
            rel = canonical.removeprefix("memory/").casefold()
            self.names.update(n for n in ("memory/" + rel, rel, "memory/" + rel.removesuffix(".md"),
                                          rel.removesuffix(".md")) if "/" in n)
            parts = rel.split("/")
            tails = ["/".join(parts[-k:]) for k in range(1, len(parts) + 1)]
            if shared(tails[0]):
                self.names.update(tail for tail in tails[1:] if not shared(tail))
            else:
                self.names.add(tails[0])
            stem = parts[-1].removesuffix(".md")
            self.names.update(n for n in (stem, DATE_PREFIX.sub("", stem)) if distinctive_slug(n) and n not in stems)
            ident = artifact_id.casefold()  # its identity: a shown file named for it shares nothing
            self.names.update(n for n in {ident, *(a.casefold() for a in aliases)}
                              if (len(n) >= 8 or distinctive_slug(n) or not n.isalpha()) and (n == ident or n not in stems))
            words = _title_words(title)
            if len(words) >= 3 and len(" ".join(words)) >= 20:
                self._titles.setdefault(words[0], set()).add(words)
        self.literals = {name for name in self.names if not _RUN.fullmatch(name) and not shared(name)}
        self.literal = _spelled(self.literals)

    @property
    def lasts(self) -> set[str]:
        if self._lasts is None:
            self._lasts = {re.split(r"[/:=#?&]", name)[-1].strip("_.!") for name in self.names} - {""}
        return self._lasts

    def titles(self) -> set[tuple[str, ...]]:
        """The held titles of three or more words and 20 or more characters that no shown document carries."""
        if self._kept is None:
            shown = self._shown_titles() if callable(self._shown_titles) else self._shown_titles
            shown = {_title_words(title) for title in shown}
            self._kept = {title for group in self._titles.values() for title in group if title not in shown}
        return self._kept

    def revision(self) -> list:
        return [sorted(self.names), sorted(self.titles()), sorted(self.literals)]

    def _named(self, run: str) -> bool:
        value = unquote(run).casefold()
        for piece in (value, *_PIECE.split(value)):  # a whole id, then each query, fragment or label part
            parts = piece.strip("_.!?/").split("/")
            if any("/".join(parts[i:]) in self.names for i in range(len(parts))):
                return True
        return False

    def spans(self, text: str) -> list[tuple[int, int]]:
        # Set tests in C first: most texts hold no held name's last segment and no whole title.
        # When casefolding kept every offset, the folded text is searched and its spans used as is.
        folded, found = text.casefold(), set()
        aligned = folded if len(folded) == len(text) else None
        if not self.lasts.isdisjoint(_SEGMENT.findall(folded)):
            found.update(_run(text, m.start(), m.end()) for m in _SEGMENT.finditer(aligned or text)
                         if m.group().casefold() in self.lasts)
        if _ESCAPE.search(text):
            found.update(m.span() for m in _RUN.finditer(text) if "%" in m.group())
        found = {(start, end) for start, end in found if self._named(text[start:end])}
        if self.literal is not None:
            found.update(_run(text, m.start(), m.end()) for m in self.literal.finditer(text))
        present = set(_WORD.findall(folded)) if self._titles else set()
        for title in {t for first in present & self._titles.keys() for t in self._titles[first] if present.issuperset(t)}:
            if aligned is not None:
                pattern = r"(?<![^\W_])" + r"[\W_]+".join(map(re.escape, title)) + r"(?![^\W_])"
                spans = {m.span() for m in re.finditer(pattern, aligned)}
            else:
                words = list(_WORD.finditer(text))
                folded_words = [w.group().casefold() for w in words]
                spans = {(words[i].start(), words[i + len(title) - 1].end()) for i in range(len(words))
                         if tuple(folded_words[i:i + len(title)]) == title}
            if spans and title in self.titles():  # a title a shown document carries too is ordinary words
                found.update(spans)
        return sorted(found)

    def redact(self, text: str) -> str:
        """Strip every held name; the last pass finding none is the leak check, else it raises."""
        for _ in range(5):
            spans = self.spans(text)
            if not spans:
                return text
            text = _strip(text, spans)
        raise RedactionError("leak check failed: a held name survived redaction")

    def scrub(self, value: Any, keys: bool = True) -> Any:
        """Every string in a value redacted: nested lists, tuples and dicts, their keys too unless ``keys`` is
        False (a caller's own field names)."""
        if isinstance(value, str):
            return self.redact(value)
        if isinstance(value, (list, tuple)):
            return type(value)(self.scrub(item, keys) for item in value)
        if isinstance(value, dict):
            return {self.scrub(key) if keys else key: self.scrub(item, keys) for key, item in value.items()}
        if is_dataclass(value) and not isinstance(value, type):
            return replace(value, **{field.name: self.scrub(getattr(value, field.name), keys) for field in fields(value)})
        return value


def redact(decision, item: Any, *, root: Path, keys: bool = False) -> Any:
    """``item`` with every held name a decision strips taken out of each string it holds (``Redactor.scrub``;
    dict keys are the caller's field names and stay unless ``keys``); unchanged for an admin and for a read that holds class 1
    alone. Raises ``RedactionError`` when a name survives or the held set cannot be read. ``root`` is the memory
    root the decision's checks use."""
    from .policy import redactor  # the decision's held set, judged where every class is
    try:
        found = redactor(decision, root)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        raise RedactionError("the held names could not be read, so nothing is handed over") from error
    return item if found is None else found.scrub(item, keys=keys)


def identity(decision, artifact_id: str, path: str, *, root: Path) -> str:
    """An item's id as handed over: its own, or the id its path gives when it spells a held name (the
    projection's manifest rule)."""
    if redact(decision, artifact_id, root=root) == artifact_id:
        return artifact_id
    try:
        return artifact_id_from_path(path.removeprefix("memory/"))
    except ArtifactSchemaError:
        return ""


def package(decision, item: Any, *, root: Path, paths: Iterable[str] = ()) -> Any | None:
    """How memory text leaves the Runtime: ``allows`` on every path the item names, then ``redact`` on
    every string. None when a path is refused or the redaction cannot be completed."""
    from .policy import allows
    try:
        if any(not allows(decision, path, "read", root=root) for path in paths):
            return None
        return redact(decision, item, root=root)
    except RedactionError:
        return None


def kept(decision, rows: Iterable, *, root: Path, path: str | None = None) -> list:
    """Each row ``package``d on its own, under the memory path in its ``path`` field: a refused row is dropped."""
    def named(row) -> tuple[str, ...]:
        value = row.get(path) if path and isinstance(row, Mapping) else None
        return ("memory/" + value.removeprefix("memory/"),) if isinstance(value, str) and value else ()
    return [item for item in (package(decision, row, root=root, paths=named(row)) for row in rows) if item is not None]


def _keys(value: Any) -> list[str]:
    if isinstance(value, Mapping):
        return [str(key) for key in value] + [name for item in value.values() for name in _keys(item)]
    return [name for item in value for name in _keys(item)] if isinstance(value, (list, tuple)) else []


def emit(decision, value: Any, *, root: Path, paths: Iterable[str] = (), each: tuple[str, str] | None = None,
         render: Callable[[Any], str] | None = None, end: str = "\n") -> int:
    """How a read surface prints memory: ``package`` the value (``each`` = (list key, path field): that list's
    rows one by one, ``kept``), then print it, one JSON line unless ``render`` makes the text. 0 when printed;
    1, with nothing on stdout and a plain line on stderr, when it is refused."""
    import sys
    if each and isinstance(value, Mapping) and each[0] in value:
        value = {**value, each[0]: kept(decision, value[each[0]], root=root, path=each[1])}
    shown = package(decision, value, root=root, paths=paths)
    try:  # a field name memory supplies (a frontmatter map's key) is checked too; renaming one would garble it
        shown = shown if shown is None or redact(decision, names := _keys(shown), root=root) == names else None
    except RedactionError:
        shown = None
    if shown is None:
        print("egregore: this output names material held from you, so it is not shown", file=sys.stderr)
        return 1
    print(render(shown) if render else json.dumps(shown, ensure_ascii=False), end=end)
    return 0


def emit_for(runtime, actor, value: Any, **options) -> int:
    """``emit`` under the actor's read decision, in the runtime's memory."""
    from .contracts import Permission
    return emit(runtime.authorize(actor, Permission.READ), value, root=runtime.canonical_root, **options)
