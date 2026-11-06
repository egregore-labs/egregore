"""Egregore rules: good design for any reader, whatever the brand.

These ship with the Runtime to every organization and are read first, before
the organization's house rules, what the organization keeps liking, and one
person's own taste; later layers win where they conflict. The must-pass
checks (contrast, accessibility, colours from tokens, sandboxed hosting, no
internal notes in the outside copy) live in code and always hold.

Each rule says when to skip it and why it exists, so an agent can set it
aside with a reason instead of following it blindly.
"""

from __future__ import annotations

EGREGORE_RULES: tuple[dict[str, str], ...] = (
    {
        "rule": "Design every page from its content; never ship a stock template.",
        "skip": "A form the reader already knows and expects, such as a receipt.",
        "why": "Examples inspire; a skeleton reused as-is makes every page read the same.",
    },
    {
        "rule": "The first view is a complete frame: nothing cut by the fold, nothing overflowing sideways, no controls over content.",
        "skip": "Never.",
        "why": "The first screen decides whether the reader continues.",
    },
    {
        "rule": "Give one strong visual room, and keep nothing off-chart: extend the axes, or cut the items and say so.",
        "skip": "Pages with no visual argument to make.",
        "why": "A cramped or clipped figure hides the point it exists to show.",
    },
    {
        "rule": "Leave clear space between groups, and check overlaps mechanically, not by eye.",
        "skip": "Never.",
        "why": "Crowding reads as noise, and the eye misses overlaps a check catches.",
    },
    {
        "rule": "Choose sections per piece, never because a template lists them.",
        "skip": "A form whose sections the reader relies on, such as a changelog.",
        "why": "Standing sections pad a page with headings that say nothing.",
    },
    {
        "rule": "Use plain, established words and the organization's own vocabulary; coin no terms in reader-facing text.",
        "skip": "A term the organization already uses.",
        "why": "A coined word is one more thing the reader must learn before understanding.",
    },
    {
        "rule": "Introduce every term before using it, and write for someone who was not there.",
        "skip": "Pages written for the people who were in the room.",
        "why": "Pages travel further than the conversation that produced them.",
    },
    {
        "rule": "Reveal depth step by step, but let the page answer its question with no interaction.",
        "skip": "Tools and forms whose purpose is the interaction.",
        "why": "A reader who never clicks should still leave with the answer.",
    },
    {
        "rule": "Keep one design system as the chassis and one visual device per element.",
        "skip": "Never.",
        "why": "Mixed systems and stacked devices compete for attention.",
    },
    {
        "rule": "Keep geometry honest: one meaning per axis, status readable without colour, every item accounted for.",
        "skip": "Never.",
        "why": "A figure that misleads is worse than no figure.",
    },
    {
        "rule": "Move things only to explain them, and respect reduced motion.",
        "skip": "Never.",
        "why": "Decorative motion distracts and can make readers unwell.",
    },
    {
        "rule": "Keep minimum craft: no cropped glyphs, labels that fit, focus always visible and styled, never removed.",
        "skip": "Never.",
        "why": "Small defects cost trust out of proportion to their size.",
    },
    {
        "rule": "Serve two audiences from one source: mark internal notes and strip them from the outside copy.",
        "skip": "Pages that never leave the organization.",
        "why": "One source keeps both copies true; marked notes cannot leak by accident.",
    },
    {
        "rule": "A page may carry its own palette when the content calls for it, if it passes the must-pass checks.",
        "skip": "An organization with a house palette rule.",
        "why": "Colour carries meaning; the checks keep it readable.",
    },
    {
        "rule": "Draw no coloured side stripes: mark reading emphasis with a marker, a margin label or type, and status with a quiet panel whose label carries a shape.",
        "skip": "A rail that connects timeline items.",
        "why": "A stripe says only 'look here' and fails without colour; a shaped label reads in any theme.",
    },
)
