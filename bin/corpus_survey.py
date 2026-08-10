"""Look at a folder of documents before asking its owner anything about it.

Setting up a knowledge base needs three decisions: what must be kept apart, which
sources win when two disagree, and what language the documents are written in.
Asked cold, none of them are answerable. Someone who has just dropped a folder on
a machine cannot say "what must never mix" — the question is about a model of the
system, not about their files.

So this looks first. It reports the groups the folder already has, the kinds of
document inside it, and the language it can detect. The questions that follow can
then name the user's own directories and counts, and be answered yes or no.

Everything here is counting and pattern-matching. It proposes; it never decides.
Where it cannot tell — a language it does not recognise, a folder with no obvious
grouping — it says so, because a confident wrong grouping is harder to notice
than an admitted gap.
"""

from __future__ import annotations

import re
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

# Extensions worth reading. Anything else is counted and reported, not parsed.
DOCUMENT_SUFFIXES = {".pdf", ".md", ".txt", ".docx", ".doc", ".rtf", ".html", ".htm"}
CATALOGUE_SUFFIXES = {".csv", ".xlsx", ".xls", ".tsv"}

# A group needs enough documents to be worth separating. Below this it is noise —
# a stray folder, a scratch directory — and offering it as a boundary would ask
# the user to rule on something that does not matter.
MIN_GROUP = 5

# Short, very common words that are distinctive to one language. Detection here
# is deliberately crude: it only has to be right often enough to propose, and it
# reports nothing rather than guessing when the evidence is thin.
LANGUAGE_MARKERS = {
    "turkish": {"ve", "ile", "için", "olarak", "bir", "bu", "daha", "gibi", "olan"},
    "english": {"the", "and", "for", "with", "that", "this", "from", "are", "which"},
    "german": {"und", "der", "die", "das", "mit", "für", "eine", "nicht", "auch"},
    "french": {"les", "des", "est", "pour", "dans", "une", "sur", "que", "par"},
    "spanish": {"los", "las", "por", "para", "con", "una", "que", "del", "como"},
    "italian": {"che", "per", "con", "una", "del", "sono", "nella", "alla", "dei"},
}
WORD = re.compile(r"[^\W\d_]{2,}", re.UNICODE)


@dataclass
class Group:
    """A directory holding enough documents to be worth keeping separate."""

    name: str
    path: str
    documents: int

    def as_dict(self) -> dict:
        return {"name": self.name, "path": self.path, "documents": self.documents}


@dataclass
class Survey:
    root: str = ""
    documents: int = 0
    unreadable: int = 0
    groups: list = field(default_factory=list)
    by_suffix: dict = field(default_factory=dict)
    catalogues: list = field(default_factory=list)
    language: str = "unknown"
    language_evidence: dict = field(default_factory=dict)
    language_by_group: dict = field(default_factory=dict)
    sample_titles: list = field(default_factory=list)
    notes: list = field(default_factory=list)

    @property
    def needs_a_boundary_question(self) -> bool:
        """Whether separating anything is even plausible.

        One group means there is nothing to keep apart, so asking would be a
        question with one answer.
        """
        return len(self.groups) > 1

    def as_dict(self) -> dict:
        return {
            "root": self.root,
            "documents": self.documents,
            "unreadable": self.unreadable,
            "groups": [g.as_dict() for g in self.groups],
            "by_suffix": self.by_suffix,
            "catalogues": self.catalogues,
            "language": self.language,
            "language_evidence": self.language_evidence,
            "language_by_group": self.language_by_group,
            "sample_titles": self.sample_titles,
            "notes": self.notes,
        }


def detect_language(samples: list) -> tuple:
    """The language of some text, or that it cannot be told.

    Returns the name and the per-language hit counts, so a caller can show its
    working rather than assert a result. A near-tie reports unknown: proposing
    the wrong grammar produces a profile that silently finds no advice at all.
    """
    text = " ".join(samples).lower()
    words = set(WORD.findall(text))
    if len(words) < 20:
        return "unknown", {}
    scores = {lang: len(words & markers) for lang, markers in LANGUAGE_MARKERS.items()}
    ranked = sorted(scores.items(), key=lambda kv: -kv[1])
    best, best_score = ranked[0]
    runner_score = ranked[1][1] if len(ranked) > 1 else 0
    if best_score < 3 or best_score - runner_score < 2:
        return "unknown", scores
    return best, scores


def _read_head(path: Path, limit: int = 4000) -> str:
    """A little text from a file, for language detection only.

    PDFs are read too, because a corpus of documents is usually a corpus of
    PDFs. Reading only the plain-text files looks like it works and does not:
    measured on a real 922-document archive, every file but one was a PDF, so
    the language of the whole corpus was decided by a single stray markdown
    file that happened to be lying in it.

    Only the first page is taken, and a failure is silent — this informs a
    question the user will answer anyway, so it must never be the reason a
    survey fails.
    """
    suffix = path.suffix.lower()
    try:
        if suffix in {".md", ".txt", ".html", ".htm"}:
            return path.read_text(encoding="utf-8", errors="replace")[:limit]
        if suffix == ".pdf":
            import subprocess

            out = subprocess.run(
                ["pdftotext", "-f", "1", "-l", "1", "-q", str(path), "-"],
                capture_output=True, text=True, timeout=15,
            )
            return (out.stdout or "")[:limit]
    except (OSError, subprocess.SubprocessError, ValueError):
        return ""
    return ""


def survey(root, max_depth: int = 2, sample_files: int = 40) -> Survey:
    """What is in this folder, described so its owner can recognise it."""
    root_path = Path(root)
    result = Survey(root=str(root_path))
    if not root_path.is_dir():
        result.notes.append(f"{root_path} is not a folder")
        return result

    suffixes: Counter = Counter()
    per_group: Counter = Counter()
    group_paths: dict = {}
    samples: list = []
    group_samples: dict = {}
    titles: list = []

    for path in root_path.rglob("*"):
        if not path.is_file():
            continue
        # Any hidden component, not just a hidden filename. A folder holding
        # documents usually sits beside .git or .egregore, and counting those
        # would report machinery as content.
        if any(part.startswith(".") for part in path.relative_to(root_path).parts):
            continue
        suffix = path.suffix.lower()
        if suffix in CATALOGUE_SUFFIXES:
            result.catalogues.append(path.relative_to(root_path).as_posix())
            continue
        suffixes[suffix or "(no extension)"] += 1
        if suffix not in DOCUMENT_SUFFIXES:
            result.unreadable += 1
            continue
        result.documents += 1

        relative = path.relative_to(root_path)
        # The group is the outermost directory that is not the root itself. Files
        # sitting loose at the top belong to no group.
        if len(relative.parts) > 1:
            depth = min(max_depth, len(relative.parts) - 1)
            key = "/".join(relative.parts[:depth])
            per_group[key] += 1
            group_paths[key] = key

        if len(titles) < 8:
            titles.append(relative.as_posix())
        if len(samples) < sample_files:
            head = _read_head(path)
            if head:
                samples.append(head)
        if len(relative.parts) > 1:
            head = _read_head(path, limit=1500)
            if head and len(group_samples.setdefault(key, [])) < 6:
                group_samples[key].append(head)

    result.by_suffix = dict(sorted(suffixes.items(), key=lambda kv: -kv[1]))
    result.sample_titles = titles
    result.groups = [
        Group(name=key.split("/")[-1], path=group_paths[key], documents=count)
        for key, count in sorted(per_group.items(), key=lambda kv: -kv[1])
        if count >= MIN_GROUP
    ]
    result.language, result.language_evidence = detect_language(samples)
    for key, heads in group_samples.items():
        lang, _ = detect_language(heads)
        if lang != "unknown":
            result.language_by_group[key] = lang
    # A corpus in two languages needs two sets of grammar. Reporting the majority
    # language would leave every document in the other one silently unread — and
    # nothing downstream would say why they produced no advice.
    distinct = set(result.language_by_group.values())
    if len(distinct) > 1:
        result.language = "mixed"
        result.notes.append(
            "documents are in more than one language (" + ", ".join(sorted(distinct)) +
            "); each language needs its own grammar, or the others yield no advice")

    if not result.documents:
        result.notes.append("no readable documents found")
    if result.unreadable:
        result.notes.append(
            f"{result.unreadable} files are not a document type this reads; they are ignored")
    if result.documents and len(result.groups) < 2:
        # Fewer than two groups means there is nothing to hold apart, whether
        # that is because the folder is flat or because only one part of it is
        # substantial.
        result.notes.append(
            "nothing here needs separating; one boundary value will cover everything")
    if result.language == "unknown" and result.documents:
        result.notes.append(
            "could not tell the language from the text available — it must be stated, "
            "because finding advice depends on the grammar of the language")
    if result.catalogues:
        result.notes.append(
            f"found {len(result.catalogues)} spreadsheet(s) that may describe these documents")
    return result


def boundary_question(result: Survey) -> dict | None:
    """The separation question, phrased with the owner's own folder names.

    Returns None when there is nothing to separate, so the caller asks nothing
    rather than asking a question with one possible answer.
    """
    if not result.needs_a_boundary_question:
        return None
    names = [g.name for g in result.groups[:3]]
    return {
        "found": [g.as_dict() for g in result.groups],
        "question": (
            f"Your folders are {', '.join(names)}. Are these different SUBJECTS, "
            f"or things that must never be mixed?\n\n"
            f"Separating them means a question about {names[0]} can never be answered "
            f"from {names[1]} — not even when that is where the answer is."
        ),
        # Together first: most folder structures are subjects, and separating
        # subjects removes real answers. Keeping them apart is the choice that
        # needs a reason, so it is the one stated second.
        "options": [
            {"label": "Subjects — keep them together",
             "effect": "one boundary value for everything",
             "example": "pruning, fertiliser, pests — a question may need any of them"},
            {"label": f"Must not mix — separate {', '.join(names)}",
             "effect": "one boundary value per folder",
             "example": "one client's contract must never answer for another"},
        ],
    }


def trust_question(result: Survey) -> dict | None:
    """The ranking question, listing what was actually found."""
    if not result.groups:
        return None
    return {
        "found": [g.as_dict() for g in result.groups],
        "question": ("Two of these disagree about the same thing. Which should win?"),
        "options": [{"label": g.name, "documents": g.documents} for g in result.groups[:4]]
        + [{"label": "Don't know", "effect": "nothing is ranked above anything else"}],
    }


def summarise(result: Survey) -> str:
    """The survey as the owner reads it, before any question is asked."""
    lines = [f"{result.documents:,} documents in {result.root}"]
    if result.groups:
        lines.append("")
        lines.append("groups:")
        for g in result.groups[:6]:
            lines.append(f"  {g.path:<40} {g.documents:>6,} documents")
    if result.by_suffix:
        kinds = ", ".join(f"{k} {v:,}" for k, v in list(result.by_suffix.items())[:5])
        lines.append("")
        lines.append(f"file types: {kinds}")
    lines.append(f"language: {result.language}")
    for note in result.notes:
        lines.append(f"  ! {note}")
    return "\n".join(lines)
