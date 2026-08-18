"""Typed memories: no upload, no audio, no transcription — same recall.

The load-bearing claim here is that a memory someone *wrote* is as findable as
one they spoke. Asserting it was created is not enough; the RAG test below is
what proves enrichment, chunking, embedding and indexing all really ran.
"""

from tests.conftest import auth, set_tier


def test_typed_memory_is_enriched_and_indexed(make_text_memory):
    rec = make_text_memory("alice", "Today I hiked Table Mountain with Sarah. It was beautiful.")

    assert rec["status"] == "indexed"
    assert rec["source"] == "text"
    assert rec["audio_path"] == ""
    assert rec["duration_sec"] == 0.0
    # The typed text *is* the transcript — nothing transcribed it.
    assert rec["transcript"] == "Today I hiked Table Mountain with Sarah. It was beautiful."
    assert rec["title"]
    assert rec["summary"]
    assert "Sarah" in rec["people"] or "Table" in rec["people"]


def test_typed_memory_is_recallable(make_text_memory, client):
    """The whole point: it must come back out of a question, with a citation."""
    make_text_memory("alice", "I finally learned to make my grandmother's rasam recipe.")

    answer = client.post(
        "/chat", json={"question": "What did I cook?"}, headers=auth("alice")
    )
    assert answer.status_code == 200
    citations = answer.json()["citations"]
    assert citations, "a typed memory was never indexed for retrieval"
    assert citations[0]["source"] == "text"


def test_typed_memory_can_be_backdated(make_text_memory):
    rec = make_text_memory("alice", "A memory from long ago.", event_date="2020-01-15")
    assert rec["event_date"] == "2020-01-15"


def test_typed_memory_language_is_detected(make_text_memory):
    """Nothing told us the language — enrichment has to work it out."""
    tamil = make_text_memory("alice", "இன்று நான் அம்மாவுடன் கோயிலுக்குச் சென்றேன்.")
    assert tamil["language"] == "ta"

    english = make_text_memory("alice", "We drove up the coast and stopped for coffee.")
    assert english["language"] == "en"


def test_whitespace_only_text_is_refused(client):
    r = client.post("/recordings/text", json={"text": "   \n  "}, headers=auth("alice"))
    assert r.status_code == 422
    assert client.get("/recordings", headers=auth("alice")).json() == []


def test_empty_text_is_refused(client):
    r = client.post("/recordings/text", json={"text": ""}, headers=auth("alice"))
    assert r.status_code == 422


# -- entitlements ----------------------------------------------------------


def test_free_tier_is_capped_at_1000_chars(client):
    at_limit = client.post(
        "/recordings/text", json={"text": "a" * 1000}, headers=auth("alice")
    )
    assert at_limit.status_code == 201

    over = client.post("/recordings/text", json={"text": "a" * 1001}, headers=auth("alice"))
    assert over.status_code == 413
    detail = over.json()["detail"]
    assert detail["error"] == "text_too_long"
    assert detail["limit"] == 1000
    assert detail["tier"] == "free"


def test_premium_tier_is_capped_at_10000_chars(client):
    set_tier("alice", "premium")

    long_but_allowed = client.post(
        "/recordings/text", json={"text": "a" * 10000}, headers=auth("alice")
    )
    assert long_but_allowed.status_code == 201

    over = client.post("/recordings/text", json={"text": "a" * 10001}, headers=auth("alice"))
    assert over.status_code == 413
    assert over.json()["detail"]["limit"] == 10000
    assert over.json()["detail"]["tier"] == "premium"


def test_the_cap_is_measured_after_trimming(client):
    """Leading/trailing whitespace is stripped before storing, so it must not count."""
    padded = "  " + "a" * 1000 + "  "
    assert client.post(
        "/recordings/text", json={"text": padded}, headers=auth("alice")
    ).status_code == 201


def test_one_users_premium_does_not_raise_anothers_cap(client):
    set_tier("alice", "premium")
    over_for_bob = client.post(
        "/recordings/text", json={"text": "a" * 5000}, headers=auth("bob")
    )
    assert over_for_bob.status_code == 413


def test_profile_reports_the_tier_and_cap(client):
    free = client.get("/profile", headers=auth("alice")).json()
    assert free["tier"] == "free"
    assert free["text_max_chars"] == 1000

    set_tier("alice", "premium")
    premium = client.get("/profile", headers=auth("alice")).json()
    assert premium["tier"] == "premium"
    assert premium["text_max_chars"] == 10000


# -- the audio-shaped endpoints ---------------------------------------------


def test_no_audio_url_is_minted_for_a_typed_memory(make_text_memory, client):
    rec = make_text_memory("alice", "Nothing to play here.")
    got = client.get(f"/recordings/{rec['id']}", headers=auth("alice"))
    assert got.status_code == 200
    assert got.json()["audio_url"] == ""


def test_audio_endpoint_404s_for_a_typed_memory(make_text_memory, client):
    rec = make_text_memory("alice", "Nothing to play here.")
    r = client.get(f"/recordings/{rec['id']}/audio", headers=auth("alice"))
    assert r.status_code == 404
    assert r.json()["detail"] == "Audio not available"


def test_deleting_a_typed_memory_needs_no_blob(make_text_memory, client):
    rec = make_text_memory("alice", "Delete me.")
    assert client.delete(f"/recordings/{rec['id']}", headers=auth("alice")).status_code == 204
    assert client.get("/recordings", headers=auth("alice")).json() == []


def test_typed_memories_are_scoped_to_their_owner(make_text_memory, client):
    make_text_memory("alice", "Alice wrote this.")
    assert client.get("/recordings", headers=auth("bob")).json() == []


# -- statistics --------------------------------------------------------------


def test_a_typed_memory_stays_out_of_the_duration_series(make_text_memory, make_recording):
    """A written memory is not a zero-second recording.

    Counting it as one would drag the average recording length toward zero and
    pile every typed memory into the shortest duration bucket.
    """
    from datetime import date, timedelta

    from app.services.firestore import get_repository

    repo = get_repository()
    make_recording("alice", "A spoken memory.")  # duration 5.0
    make_text_memory("alice", "A written memory.")

    # A window, not `date.today()`: the counters are keyed by the recording's UTC
    # day, which is not the local one for part of every day.
    today = date.today()
    (daily,) = repo.list_daily(today - timedelta(days=1), today + timedelta(days=1))
    assert daily.recordings == 2, "a typed memory is still a memory"
    assert daily.recording_seconds == 5.0, "typed memories leaked into the duration total"
    assert sum(daily.duration_buckets.values()) == 1

    stats = repo.get_user_stats("alice")
    assert stats.recordings_count == 2
