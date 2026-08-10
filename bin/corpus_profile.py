"""Build a publisher profile from a survey and a few answers.

The profile is the file that decides everything downstream: which documents may
answer which question, which source wins a disagreement, and what a sentence
carrying advice looks like. Writing it by hand needs someone who knows both the
corpus and the system, which is nobody at the point where a customer has just
dropped a folder on a machine.

So it is generated. The survey supplies the folders and the language; the
operator supplies two decisions; this turns both into the file. Nothing here
exercises judgment — the same survey and the same answers always produce the
same profile, which matters because a profile that drifts silently changes what
the archive is willing to say.

The grammar packs are the one part that is knowledge rather than configuration.
What obligation looks like in Turkish is a fact about Turkish, not about any
customer, so it ships here and a profile references it. A language with no pack
yields no advice from its documents, and the profile says so in writing rather
than leaving someone to discover it from an empty result.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

# What advice looks like, per language. These are facts about a language rather
# than about a corpus, so they belong in the framework and not in any instance.
#
# The line is drawn at the domain: seasons and "if there is" are Turkish, while
# flowering, harvest and sloped land are agriculture. An instance adds the second
# kind to what it inherits here. Measured against a hand-tuned olive profile,
# these packs recover most of it, and the remainder is exactly the vocabulary a
# crop specialist would supply.
#
# The English pack was first written against olive research papers and inherited
# their vocabulary — it matched "growers should" and "before harvest", and found
# nothing at all in 897 ordinary English documents. A pack named for a language
# has to work on that language, not on one corpus in it.
#
# It stays narrower than the Turkish pack for a real reason: measured on twenty
# research papers, a broad "must|should + verb" recorded seventeen descriptions
# as instructions. The passive form is the compromise — it is how instructions
# are written, and descriptions of a subject rarely take it. Cognitive verbs are
# excluded because "it should be noted" is how prose addresses a reader, not how
# a document tells someone to act; measured, they were most of what survived.
GRAMMAR_PACKS = {
    "turkish": {
        "_note": ("Obligation is carried by verb suffixes (-malı/-meli). Negation is the "
                  "-ma/-me infix immediately before the modal, so yapılmalıdır and "
                  "yapılmamalıdır differ by two letters and mean opposite things."),
        "obligation": [r"\w+[mM][aeAE][lL][ıiİI](?:dır|dir|dur|dür)?\b",
                       r"\bgerek(?:ir|mektedir|lidir)\b", r"\böneril(?:ir|mektedir)\b",
                       r"\btavsiye edil(?:ir|mektedir)\b", r"\buygulan(?:ır|malıdır)\b",
                       r"\byapıl(?:ır|malıdır)\b", r"\bdikkat edil(?:meli|melidir)\b"],
        "negation": [r"\w+[mM][aeAE][mM][aeAE][lL][ıiİI](?:dır|dir)?\b",
                     r"\byapılmama(?:lı|sı)\b", r"\bverilmeme(?:li|si)\b",
                     r"\bkullanılmama(?:lı|sı)\b", r"\bkaçınıl(?:malı|malıdır|ması)\b"],
        "condition": [r"\b\w+(?:se|sa)\b(?=\s)",
                      r"\b(?:durumunda|halinde|hâlinde|takdirde|koşullarda|şartlarda)\b",
                      r"\bvarsa\b", r"\bolduğunda\b", r"\bgörüldüğünde\b"],
        "time": [r"\b(?:ocak|şubat|mart|nisan|mayıs|haziran|temmuz|ağustos|eylül|ekim|kasım|aralık)\b",
                 r"\b(?:ilkbahar|sonbahar|yaz|kış)\b",
                 r"\b\d+\s*(?:gün|hafta|ay)\s*(?:önce|sonra|arayla|içinde)\b"],
        "observation": [r"\b(?:görülür|gözlenir|oluşur|bulunur|artar|azalır)\b",
                        r"\b(?:tespit edilmiştir|belirlenmiştir|gözlenmiştir|saptanmıştır|bulunmuştur)\b",
                        r"\b(?:olmalıdır|bulunmalıdır)\b"],
    },
    "english": {
        "_note": ("Narrow on purpose. Broad modal forms read descriptions as "
                  "instructions in research prose."),
        "obligation": [r"\bit\s+is\s+recommended\b", r"\bwe\s+recommend\b",
                       r"\bare\s+recommended\s+to\b",
                       r"\b(?:must|should|shall)\s+(?:be\s+)?(?!observed|noted|mentioned|"
                       r"considered|understood|remembered|emphasi[sz]ed|highlighted|stressed|"
                       r"recalled)\w+ed\b",
                       r"\bneeds?\s+to\s+be\b", r"\bis\s+required\s+to\b",
                       r"\bwe\s+(?:decided|agreed|chose)\b"],
        "negation": [r"\b(?:must|should|shall)\s+not\b", r"\bdo\s+not\s+\w+",
                     r"\bavoid\s+\w+ing\b"],
        "condition": [r"\bif\s+\w+", r"\bwhen\s+\w+", r"\bin\s+case\s+of\b",
                      r"\bprovided\s+that\b"],
        "time": [r"\b(?:January|February|March|April|May|June|July|August|September|"
                 r"October|November|December)\b",
                 r"\b\d+\s*(?:days?|weeks?|months?|years?)\s*(?:before|after|later)\b",
                 r"\b(?:daily|weekly|monthly|annually|quarterly)\b"],
        "observation": [r"\b(?:was|were)\s+(?:observed|recorded|measured|found|determined)\b",
                        r"\bresults?\s+(?:show|showed|indicate|indicated)\b",
                        r"\bthis\s+(?:study|paper|research)\b", r"\bwe\s+(?:found|report|conclude)\b",
                        r"\b(?:increased|decreased|correlated)\s+(?:with|significantly)\b"],
    },
}

# Document kinds, per language. Structural markers only — a legal article number,
# a gazette reference — because those are cheap and do not hallucinate.
GENRE_PACKS = {
    "turkish": {
        "regulation": [r"MADDE\s+\d+\s*[-–]", r"\bTebliğ\b", r"Resm[iî]\s*Gazete",
                       r"\bsayılı (Kanun|Karar|Cumhurbaşkanı)\b"],
        "guidance": [r"Mücadele\s+(Yöntemleri|Metotları)", r"Kültürel\s+Önlemler",
                     r"(Zararlının|Hastalığın)\s+(Tanımı|Belirtileri|Yaşayışı)"],
        "research": [r"Anahtar\s*[Kk]elimeler", r"Materyal\s+ve\s+Y[öo]ntem"],
    },
    "english": {
        "regulation": [r"\bArticle\s+\d+\b", r"\bOfficial\s+Journal\b", r"\bRegulation\s+\(E[UC]\)"],
        "guidance": [r"\bIntegrated\s+Pest\s+Management\b", r"\bCultural\s+(?:Practices|Control)\b",
                     r"\bControl\s+Methods?\b"],
        "research": [r"\bAbstract\b", r"\bMaterials?\s+and\s+Methods?\b", r"\bKeywords?\s*:",
                     r"\bdoi\s*:\s*10\.", r"\bet\s+al\.", r"\bReferences\b"],
    },
}

SLUG = re.compile(r"[^a-z0-9]+")


def slug(text: str) -> str:
    return SLUG.sub("-", (text or "").lower()).strip("-") or "group"


def merge_packs(languages: list, packs: dict) -> tuple:
    """One combined pack for every language present, and the ones with none.

    Patterns from different languages sit side by side rather than being chosen
    between, because a single document can hold both — a Turkish paper with an
    English abstract is the ordinary case, not an edge one.
    """
    merged: dict = {}
    missing = []
    for language in languages:
        pack = packs.get(language)
        if pack is None:
            missing.append(language)
            continue
        for key, patterns in pack.items():
            if key.startswith("_") or not isinstance(patterns, list):
                continue
            for pattern in patterns:
                merged.setdefault(key, [])
                if pattern not in merged[key]:
                    merged[key].append(pattern)
    return merged, missing


def build(survey_result, separate_groups: bool, trust_order: list | None = None,
          boundary_key: str = "collection") -> dict:
    """The profile that a survey and two answers imply.

    `separate_groups` is the operator's answer to whether the folders are subjects
    or things that must be kept apart. `trust_order` ranks the groups, best first;
    an empty ranking leaves every source equal, which is honest when nobody knows.
    """
    languages = sorted(set(survey_result.language_by_group.values())) or (
        [survey_result.language] if survey_result.language not in ("unknown", "mixed") else []
    )
    grammar, missing_grammar = merge_packs(languages, GRAMMAR_PACKS)
    genres, _ = merge_packs(languages, GENRE_PACKS)

    order = [g for g in (trust_order or []) if g]
    tiers = {}
    for index, name in enumerate(order):
        # Three tiers, best first. Beyond the third everything shares the lowest,
        # because a ranking finer than the evidence supports is invented.
        tiers[name] = f"T{min(index + 1, 3)}"

    rules = []
    for group in survey_result.groups:
        rule = {
            "match": {"path_prefix": group.path},
            "tier": tiers.get(group.name, "T2"),
        }
        if separate_groups:
            rule["boundary"] = {boundary_key: slug(group.name)}
        rules.append(rule)

    profile = {
        "_generated": (
            "Written from a folder survey and two answers. Regenerating from the same "
            "survey and answers produces the same file."),
        "boundary_key": boundary_key,
        "rules": rules,
        "claim_grammar": grammar,
        "document_genres": genres,
        "genre_preferences": {"guidance": 1.0, "research": 0.9, "regulation": 0.35,
                              "_default": 1.0},
        "open": [],
    }

    if not separate_groups:
        profile["open"].append(
            "All documents share one boundary value. Any document may answer any "
            "question. Change this if some of them must never be mixed.")
    if not order:
        profile["open"].append(
            "No source is ranked above another. Every document carries tier T2, so a "
            "disagreement is shown rather than resolved.")
    if missing_grammar:
        profile["open"].append(
            "No advice grammar exists for: " + ", ".join(missing_grammar) +
            ". Documents in those languages yield no advice at all until one is added.")
    if survey_result.language == "unknown":
        profile["open"].append(
            "The language could not be detected, so no advice grammar was chosen and "
            "no advice will be found. State the language to fix this.")
    if survey_result.catalogues:
        profile["open"].append(
            "Spreadsheets were found beside the documents (" +
            ", ".join(survey_result.catalogues[:3]) +
            "). If one describes these documents, add a catalogue block to use it.")
    return profile


def write(profile: dict, path) -> Path:
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(profile, ensure_ascii=False, indent=2) + "\n",
                      encoding="utf-8")
    return target


def summarise(profile: dict) -> str:
    """What the generated profile will and will not do."""
    lines = [
        f"boundary: {profile.get('boundary_key')}",
        f"rules: {len(profile.get('rules', []))} folder(s)",
        f"advice patterns: {sum(len(v) for v in profile.get('claim_grammar', {}).values())}",
        f"document kinds: {', '.join(profile.get('document_genres', {}) or ['none'])}",
    ]
    for item in profile.get("open", []):
        lines.append(f"  ! {item}")
    return "\n".join(lines)
