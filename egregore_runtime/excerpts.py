"""Local lexical passage selection; no source-specific rules or model calls."""
import math
import re
from collections import Counter

STOP = frozenset("a an and are as at be been both each other any some such also only then than not no very most more same so by can could did do does for from had has have how i if in into is it its me my of on or our that the their them these they this those through to us was we were what when where which who why will with would you your".split())

def terms(text):
    return {word for word in re.findall(r"[^\W\d_]+", text.casefold())
            if len(word) > 2 and word not in STOP}

def select_excerpt(passage, question, limit=600):
    text = passage or ""
    if len(text) <= limit:
        return text
    query = terms(question)
    if not query:
        return text[:limit]
    # Candidate windows start at paragraph boundaries and remain contiguous.
    starts = [0] + [match.end() for match in re.finditer(r"\n\s*\n", text)]
    windows = []
    for start in starts:
        if not text[start:].strip():
            continue
        window = text[start:start + limit]
        # Keep complete paragraphs, including qualifications, when they fit.
        if start + limit < len(text):
            boundaries = list(re.finditer(r"\n\s*\n", window))
            if boundaries:
                window = window[:boundaries[-1].start()]
        window = re.sub(r"(?:^|\n)#+[^\n]*\s*$", "", window).rstrip()
        if window:
            windows.append(window)
    if not windows:
        return text[:limit]
    tokens = [terms(window) for window in windows]
    counts = Counter(term for window in tokens for term in window)
    def score(index):
        overlap = query & tokens[index]
        return sum(math.log(1 + len(windows) / counts[term]) for term in overlap)
    best = max(range(len(windows)), key=score)
    return windows[best] if score(best) > 0 else text[:limit]
