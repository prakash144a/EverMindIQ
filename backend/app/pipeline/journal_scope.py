"""Working out which journal a question is about, from the question alone.

The Recall screen has an explicit scope picker, and that is the primary control.
This is the second path: someone who types "what did I say about travel?" means
their Travel journal, and making them reach for a dropdown to say so would waste
the fact that they already said it.

Deliberately **not** an LLM call. A router model would add a round trip and its
cost to every single question asked, forever, to interpret a handful of names the
user typed themselves. A word match over those names is predictable, free, and
— because the answer always reports which journal it used, and the app offers
one tap to widen — safe to get wrong.
"""

from __future__ import annotations

import re

from app.models.journal import Journal


def _name_pattern(name: str) -> re.Pattern[str]:
    """Match `name` as whole words, tolerating a plural.

    Word boundaries stop "Art" from matching "particularly". The optional
    trailing "s"/"es" catches "my travels" for a journal called Travel; it will
    not catch "travelling", which is the accepted limit of a match this cheap.
    """
    words = r"\s+".join(re.escape(w) for w in name.split())
    return re.compile(rf"\b{words}(?:e?s)?\b", re.IGNORECASE)


def detect_journal(question: str, journals: list[Journal]) -> Journal | None:
    """The journal a question names, if it names exactly one.

    Returns None when nothing matches, and also when two *different* journals
    match: a question mentioning both Travel and Politics is genuinely about
    both, and silently picking one would hide half the answer. Not scoping is
    the recoverable failure; scoping to the wrong journal is not.

    Where names overlap ("Work" and "Work Trips"), the longest match wins — it
    is the more specific thing the user said.
    """
    if not question or not journals:
        return None

    matched = [j for j in journals if _name_pattern(j.name).search(question)]
    if not matched:
        return None
    if len(matched) == 1:
        return matched[0]

    # Several matched. If one name contains all the others it is simply the
    # more specific spelling of the same phrase ("Work Trips" also matches
    # "Work"), so take it. Otherwise the question really does span journals.
    matched.sort(key=lambda j: len(j.name), reverse=True)
    longest = matched[0]
    folded = longest.name.casefold()
    if all(j.name.casefold() in folded for j in matched[1:]):
        return longest
    return None


__all__ = ["detect_journal"]
