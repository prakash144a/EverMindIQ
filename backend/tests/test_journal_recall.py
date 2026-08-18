"""Scoped recall — the reason journals exist.

Filing memories is only tidying. The feature is that asking about one journal
answers from that journal alone, so a question about a trip stops dredging up
the argument about politics that happened during it.

The load-bearing assertions here are the *absences*: a memory from another
journal must not appear in the citations. A test that only checks the right
memory came back would pass just as happily with no filtering at all.
"""

from __future__ import annotations

from app.models.journal import Journal
from app.pipeline.journal_scope import detect_journal
from tests.conftest import auth, set_tier

COAST = "We drove up the coast road and stopped for idli at a roadside stall."
ELECTION = "The election result came through and the whole street was arguing."

# A question that genuinely retrieves BOTH memories when nothing is filtering.
# The exclusion tests below depend on that: asked something only the Travel
# memory matches, they would pass just as happily with the journal filter
# removed entirely, and prove nothing. (The mock embedder is a bag of words, so
# the question has to share vocabulary with both.)
REACHES_BOTH = "the road and the street"


def setup_two_journals(client, uid: str = "u1") -> tuple[dict, dict]:
    """Two journals, one memory filed in each. The fixture for everything below."""
    set_tier(uid, "premium")
    travel = client.post("/journals", json={"name": "Travel"}, headers=auth(uid)).json()
    politics = client.post("/journals", json={"name": "Politics"}, headers=auth(uid)).json()
    for text, journal in ((COAST, travel), (ELECTION, politics)):
        resp = client.post(
            "/recordings/text",
            json={"text": text, "journal_id": journal["id"]},
            headers=auth(uid),
        )
        assert resp.status_code == 201, resp.text
    return travel, politics


def snippets(body: dict) -> list[str]:
    return [c["snippet"] for c in body["citations"]]


# -- the explicit scope picker ------------------------------------------------


def test_an_unscoped_question_can_reach_both_journals(client):
    """The baseline. Without this, the scoped tests below prove nothing."""
    setup_two_journals(client)
    body = client.post(
        "/chat", json={"question": REACHES_BOTH, "journal_id": ""}, headers=auth("u1")
    ).json()
    assert sorted(snippets(body)) == sorted([COAST, ELECTION])
    assert body["journal_id"] == ""


def test_scoping_to_a_journal_excludes_every_other_journal(client):
    travel, _ = setup_two_journals(client)
    body = client.post(
        "/chat", json={"question": REACHES_BOTH, "journal_id": travel["id"]}, headers=auth("u1")
    ).json()

    assert snippets(body) == [COAST]
    assert ELECTION not in " ".join(snippets(body)), "a scoped answer must not cite another journal"
    assert body["journal_id"] == travel["id"]
    assert body["journal_name"] == "Travel"


def test_scoping_excludes_unfiled_memories_too(client):
    travel, _ = setup_two_journals(client)
    client.post(
        "/recordings/text",
        json={"text": "A loose thought about the street and the road."},
        headers=auth("u1"),
    )

    body = client.post(
        "/chat", json={"question": REACHES_BOTH, "journal_id": travel["id"]}, headers=auth("u1")
    ).json()
    assert snippets(body) == [COAST]


def test_a_scoped_question_with_nothing_to_find_names_the_journal(client):
    """The generic "no memories" line would be a lie here.

    The memory may well exist — just filed somewhere else — and saying so is
    what tells the user to widen rather than assume nothing was recorded.
    """
    travel, _ = setup_two_journals(client)
    empty = client.post("/journals", json={"name": "Sports"}, headers=auth("u1")).json()

    body = client.post(
        "/chat", json={"question": REACHES_BOTH, "journal_id": empty["id"]}, headers=auth("u1")
    ).json()
    assert body["citations"] == []
    assert "Sports" in body["answer"]
    assert body["journal_name"] == "Sports"


def test_scoping_to_another_users_journal_finds_nothing(client):
    setup_two_journals(client, "alice")
    stranger = client.post("/journals", json={"name": "Travel"}, headers=auth("bob")).json()

    body = client.post(
        "/chat",
        json={"question": REACHES_BOTH, "journal_id": stranger["id"]},
        headers=auth("bob"),
    ).json()
    assert body["citations"] == []


# -- detection from the question itself ---------------------------------------


def test_naming_a_journal_in_the_question_scopes_the_answer(client):
    travel, _ = setup_two_journals(client)
    body = client.post(
        "/chat", json={"question": "what did I say about travel?"}, headers=auth("u1")
    ).json()

    assert body["journal_id"] == travel["id"]
    assert snippets(body) == [COAST]


def test_an_explicit_empty_scope_suppresses_detection(client):
    """"Ask all memories" has to win over the wording of the question.

    Otherwise the widen action would silently re-narrow to the same journal and
    look broken.
    """
    setup_two_journals(client)
    body = client.post(
        "/chat",
        json={"question": f"what did I say about travel, {REACHES_BOTH}?", "journal_id": ""},
        headers=auth("u1"),
    ).json()

    assert body["journal_id"] == ""
    assert ELECTION in snippets(body), "an explicit 'everything' must not be re-narrowed"


def test_a_question_naming_no_journal_stays_unscoped(client):
    setup_two_journals(client)
    body = client.post("/chat", json={"question": REACHES_BOTH}, headers=auth("u1")).json()
    assert body["journal_id"] == ""


def test_a_question_naming_two_journals_declines_to_scope(client):
    """Ambiguity resolves to the whole library, not to a coin flip.

    Answering from one of the two would hide half of what was asked for, and the
    user has no way to tell that happened.
    """
    setup_two_journals(client)
    body = client.post(
        "/chat",
        json={"question": f"travel and politics: {REACHES_BOTH}?"},
        headers=auth("u1"),
    ).json()

    assert body["journal_id"] == ""
    assert sorted(snippets(body)) == sorted([COAST, ELECTION])


# -- the matcher itself, without a request --------------------------------------


def journals(*names: str) -> list[Journal]:
    return [Journal(id=n.lower(), name=n) for n in names]


def test_detection_is_case_insensitive_and_tolerates_a_plural():
    js = journals("Travel")
    assert detect_journal("What did I say about TRAVEL?", js) is js[0]
    assert detect_journal("my travels last year", js) is js[0]


def test_detection_does_not_match_inside_another_word():
    """Word boundaries, or "Art" would match "particularly" and scope silently."""
    assert detect_journal("I particularly liked it", journals("Art")) is None


def test_detection_prefers_the_longer_overlapping_name():
    js = journals("Work", "Work Trips")
    assert detect_journal("what about my work trips?", js).name == "Work Trips"


def test_detection_handles_no_journals_and_an_empty_question():
    assert detect_journal("anything", []) is None
    assert detect_journal("", journals("Travel")) is None


def test_detection_does_not_match_a_merely_similar_word():
    """The documented limit of a matcher this cheap, pinned so it stays known."""
    assert detect_journal("I was travelling", journals("Travel")) is None
