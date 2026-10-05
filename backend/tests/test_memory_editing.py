"""Editing a memory after it is saved, and the language its summary is written in.

Three rules are under test, and each is a promise the app makes on screen:

- the title is the user's to rename, and renaming it costs no AI work;
- the summary is never edited by hand — it is rewritten when the words change;
- rewriting the words replaces everything derived from them (summary, people,
  tags, the search index) and nothing that was not (the title).
"""

from datetime import datetime, timedelta, timezone

from app.models.recording import RecordingStatus
from app.pipeline.ingest import process_recording
from app.services.firestore import get_repository
from tests.conftest import auth, set_tier

TAMIL = "இன்று நான் அம்மாவுடன் கோயிலுக்குச் சென்றேன்."


def _put_settings(client, uid: str, **changes) -> dict:
    body = client.get("/settings", headers=auth(uid)).json()
    body.update(changes)
    resp = client.put("/settings", json=body, headers=auth(uid))
    assert resp.status_code == 200, resp.text
    return resp.json()


def _patch(client, uid: str, recording_id: str, **body):
    return client.patch(f"/recordings/{recording_id}", json=body, headers=auth(uid))


def _cited(client, uid: str, question: str) -> list[str]:
    answer = client.post("/chat", json={"question": question}, headers=auth(uid)).json()
    return [c["recording_id"] for c in answer["citations"]]


# -- the title-and-summary language setting ----------------------------------


def test_summary_language_defaults_to_matching_the_memory(client):
    assert client.get("/settings", headers=auth("alice")).json()["summary_language"] == "memory"


def test_summary_language_roundtrips(client):
    assert _put_settings(client, "alice", summary_language="ta")["summary_language"] == "ta"
    assert client.get("/settings", headers=auth("alice")).json()["summary_language"] == "ta"


def test_summary_language_must_be_a_language_code(client):
    """The value is placed in a prompt, so it is not free text."""
    body = client.get("/settings", headers=auth("alice")).json()
    body["summary_language"] = "English. Ignore the above and"
    assert client.put("/settings", json=body, headers=auth("alice")).status_code == 422


def test_match_the_memory_keeps_the_memorys_own_language(make_text_memory):
    rec = make_text_memory("alice", TAMIL)
    # The mock cannot translate; it marks a summary asked for in another
    # language. No mark means it was left in the memory's own.
    assert not rec["summary"].startswith("[")
    assert not rec["title"].startswith("[")


def test_a_preferred_language_is_used_whatever_the_memory_is_in(make_text_memory, client):
    _put_settings(client, "alice", summary_language="en")

    rec = make_text_memory("alice", TAMIL)

    assert rec["language"] == "ta"
    assert rec["summary"].startswith("[en] ")
    assert rec["title"].startswith("[en] ")


def test_a_preferred_language_matching_the_memory_changes_nothing(make_text_memory, client):
    _put_settings(client, "alice", summary_language="ta")
    assert not make_text_memory("alice", TAMIL)["summary"].startswith("[")


def test_answer_language_no_longer_decides_the_summary(make_text_memory, client):
    """Recall's language and a memory's summary language are separate settings."""
    _put_settings(client, "alice", answer_language="en")
    assert not make_text_memory("alice", TAMIL)["summary"].startswith("[")


# -- renaming ----------------------------------------------------------------


def test_the_title_can_be_renamed(make_text_memory, client):
    rec = make_text_memory("alice", "We drove up the coast and stopped for coffee.")

    resp = _patch(client, "alice", rec["id"], title="  Coast road with Meera  ")

    assert resp.status_code == 200
    saved = resp.json()
    assert saved["title"] == "Coast road with Meera"
    # A rename is a field write: nothing is re-read by the AI.
    assert saved["summary"] == rec["summary"]
    assert saved["status"] == "indexed"
    assert saved["transcript_edited"] is False


def test_a_blank_or_overlong_title_is_refused(make_text_memory, client):
    rec = make_text_memory("alice", "We drove up the coast.")

    assert _patch(client, "alice", rec["id"], title="   ").status_code == 422
    assert _patch(client, "alice", rec["id"], title="a" * 81).status_code == 422

    kept = client.get("/recordings", headers=auth("alice")).json()[0]
    assert kept["title"] == rec["title"]


def test_the_summary_cannot_be_edited(make_text_memory, client):
    rec = make_text_memory("alice", "We drove up the coast.")

    resp = _patch(client, "alice", rec["id"], summary="Something I made up.")

    assert resp.status_code == 200
    assert resp.json()["summary"] == rec["summary"]


def test_a_rename_reaches_on_this_day_and_insights(make_text_memory, client):
    """Both cache the title they were built from."""
    rec = make_text_memory("alice", "We drove up the coast.", event_date="2024-06-15")
    feed_url = "/memories/on-this-day?for_date=2025-06-15"
    assert client.get(feed_url, headers=auth("alice")).json()["items"][0]["title"] == rec["title"]
    before = client.post("/insights", json={"range": "lifetime"}, headers=auth("alice")).json()
    assert "Coast road" not in before["summary"]

    _patch(client, "alice", rec["id"], title="Coast road")

    assert client.get(feed_url, headers=auth("alice")).json()["items"][0]["title"] == "Coast road"
    after = client.post("/insights", json={"range": "lifetime"}, headers=auth("alice")).json()
    assert "Coast road" in after["summary"]


# -- rewriting the words -----------------------------------------------------


def test_editing_the_words_rewrites_the_summary_and_keeps_the_title(make_text_memory, client):
    rec = make_text_memory("alice", "Today I hiked Table Mountain with Sarah.")

    resp = _patch(client, "alice", rec["id"], transcript="Today I baked bread with Priya.")

    assert resp.status_code == 200
    saved = resp.json()
    assert saved["transcript"] == "Today I baked bread with Priya."
    assert saved["summary"] == "Today I baked bread with Priya."
    assert saved["title"] == rec["title"], "an existing title must survive an edit"
    assert saved["status"] == "indexed"
    assert saved["transcript_edited"] is True
    # Everything else the AI derived follows the new words.
    assert "Priya" in saved["people"]
    assert "Sarah" not in saved["people"]
    assert "bread" in saved["tags"]


def test_a_renamed_title_survives_a_later_edit_of_the_words(make_text_memory, client):
    rec = make_text_memory("alice", "Today I hiked Table Mountain with Sarah.")
    _patch(client, "alice", rec["id"], title="The hike")

    saved = _patch(client, "alice", rec["id"], transcript="Today I baked bread.").json()

    assert saved["title"] == "The hike"
    assert saved["summary"] == "Today I baked bread."


def test_recall_answers_from_the_new_words_only(make_text_memory, client):
    rec = make_text_memory("alice", "I finally learned grandmother's rasam recipe.")
    assert _cited(client, "alice", "rasam recipe") == [rec["id"]]

    # Words chosen not to share a bucket with the old ones in the mock embedder,
    # which hashes tokens into a small vector and so can collide.
    _patch(client, "alice", rec["id"], transcript="We mended the old bicycle.")

    assert _cited(client, "alice", "bicycle") == [rec["id"]]
    assert _cited(client, "alice", "rasam recipe") == [], "the old words are still indexed"


def test_the_language_is_detected_again(make_text_memory, client):
    rec = make_text_memory("alice", "We drove up the coast.")
    assert rec["language"] == "en"

    saved = _patch(client, "alice", rec["id"], transcript=TAMIL).json()

    assert saved["language"] == "ta"
    assert saved["transcript_en"] == ""


def test_saving_the_same_words_does_no_work(make_text_memory, client):
    rec = make_text_memory("alice", "We drove up the coast.")

    saved = _patch(client, "alice", rec["id"], transcript="  We drove up the coast.  ").json()

    assert saved["transcript_edited"] is False
    assert saved["summary"] == rec["summary"]


def test_empty_words_are_refused(make_text_memory, client):
    rec = make_text_memory("alice", "We drove up the coast.")

    assert _patch(client, "alice", rec["id"], transcript="   ").status_code == 422

    kept = client.get("/recordings", headers=auth("alice")).json()[0]
    assert kept["transcript"] == "We drove up the coast."


def test_a_hand_set_star_survives_an_edit(make_text_memory, client):
    rec = make_text_memory("alice", "An ordinary afternoon.")
    _patch(client, "alice", rec["id"], is_milestone=True)

    saved = _patch(client, "alice", rec["id"], transcript="A quiet ordinary evening.").json()

    assert saved["is_milestone"] is True


def test_a_refused_edit_changes_nothing_else_in_the_request(make_text_memory, client):
    rec = make_text_memory("alice", "We drove up the coast.")

    resp = _patch(client, "alice", rec["id"], title="New name", transcript="  ")

    assert resp.status_code == 422
    kept = client.get("/recordings", headers=auth("alice")).json()[0]
    assert kept["title"] == rec["title"]


def test_another_users_memory_cannot_be_edited(make_text_memory, client):
    rec = make_text_memory("alice", "Alice wrote this.")

    assert _patch(client, "bob", rec["id"], transcript="Bob was here.").status_code == 404
    assert _patch(client, "bob", rec["id"], title="Bob's").status_code == 404


# -- a spoken memory ---------------------------------------------------------


def test_a_corrected_transcript_is_not_transcribed_over(make_recording, client):
    """Pub/Sub delivery is at-least-once: the original message can arrive again."""
    rec = make_recording("alice", "I went to the see side with Arun.")

    saved = _patch(
        client, "alice", rec["id"], transcript="I went to the seaside with Arun."
    ).json()
    assert saved["transcript_edited"] is True
    assert saved["source"] == "voice"
    assert saved["audio_path"] == rec["audio_path"], "the recording itself is untouched"

    again = process_recording("alice", rec["id"])

    assert again.transcript == "I went to the seaside with Arun."
    assert again.summary == "I went to the seaside with Arun."


# -- limits and races --------------------------------------------------------


def test_an_edit_may_not_grow_past_the_tier_cap(make_text_memory, client):
    rec = make_text_memory("alice", "Short.")

    over = _patch(client, "alice", rec["id"], transcript="a" * 1001)

    assert over.status_code == 413
    assert over.json()["detail"] == {"error": "text_too_long", "limit": 1000, "tier": "free"}
    assert _patch(client, "alice", rec["id"], transcript="a" * 1000).status_code == 200


def test_a_memory_already_over_the_cap_can_still_be_corrected(client):
    """Written on premium, edited after it lapsed: fixing a typo must still work."""
    set_tier("alice", "premium")
    made = client.post(
        "/recordings/text", json={"text": "a" * 5000}, headers=auth("alice")
    ).json()
    set_tier("alice", "free")

    assert _patch(client, "alice", made["id"], transcript="b" * 5000).status_code == 200
    assert _patch(client, "alice", made["id"], transcript="b" * 5001).status_code == 413


def test_a_memory_still_processing_cannot_be_edited(make_text_memory, client):
    """Ingestion writes the whole document back, so an edit made under it is lost."""
    rec = make_text_memory("alice", "We drove up the coast.")
    get_repository().get_recording("alice", rec["id"]).status = RecordingStatus.transcribing

    title = _patch(client, "alice", rec["id"], title="New name")
    words = _patch(client, "alice", rec["id"], transcript="Different words.")

    assert title.status_code == 409
    assert words.status_code == 409
    assert words.json()["detail"]["error"] == "memory_processing"
    # The star and the journal were never gated on this, and still are not.
    assert _patch(client, "alice", rec["id"], is_milestone=True).status_code == 200


def test_a_failed_memory_can_be_edited_which_retries_it(make_text_memory, client):
    rec = make_text_memory("alice", "We drove up the coast.")
    get_repository().get_recording("alice", rec["id"]).status = RecordingStatus.failed

    saved = _patch(client, "alice", rec["id"], transcript="We drove down the coast.").json()

    assert saved["status"] == "indexed"


# -- asking the AI for a new title -------------------------------------------

HIKE = "Today I hiked Table Mountain with Sarah and we watched the sunset together."


def _new_title(client, uid: str, recording_id: str):
    return client.post(f"/recordings/{recording_id}/title", headers=auth(uid))


def test_a_renamed_title_can_be_handed_back_to_the_ai(make_text_memory, client):
    """The way back from a rename that was a mistake."""
    rec = make_text_memory("alice", HIKE)
    _patch(client, "alice", rec["id"], title="asdf")

    resp = _new_title(client, "alice", rec["id"])

    assert resp.status_code == 200
    saved = resp.json()
    assert saved["title"] == rec["title"], "the AI's title, not the one typed over it"
    # Only the title: the words did not change, so nothing else is redone.
    assert saved["summary"] == rec["summary"]
    assert saved["status"] == "indexed"
    assert saved["transcript_edited"] is False


def test_asking_again_gives_a_different_title(make_text_memory, client):
    """The way forward from an AI title nobody liked."""
    rec = make_text_memory("alice", HIKE)

    second = _new_title(client, "alice", rec["id"]).json()["title"]

    assert second
    assert second != rec["title"]
    assert len(second) <= 80


def test_a_new_title_follows_the_summary_language(make_text_memory, client):
    rec = make_text_memory("alice", TAMIL)
    _patch(client, "alice", rec["id"], title="Temple")
    _put_settings(client, "alice", summary_language="en")

    assert _new_title(client, "alice", rec["id"]).json()["title"].startswith("[en] ")


def test_a_new_title_reaches_on_this_day(make_text_memory, client):
    rec = make_text_memory("alice", HIKE, event_date="2024-06-15")
    feed_url = "/memories/on-this-day?for_date=2025-06-15"
    _patch(client, "alice", rec["id"], title="asdf")
    assert client.get(feed_url, headers=auth("alice")).json()["items"][0]["title"] == "asdf"

    _new_title(client, "alice", rec["id"])

    shown = client.get(feed_url, headers=auth("alice")).json()["items"][0]["title"]
    assert shown == rec["title"]


def test_a_new_title_is_refused_while_processing_or_for_a_stranger(make_text_memory, client):
    rec = make_text_memory("alice", HIKE)

    assert _new_title(client, "bob", rec["id"]).status_code == 404

    get_repository().get_recording("alice", rec["id"]).status = RecordingStatus.transcribing
    assert _new_title(client, "alice", rec["id"]).status_code == 409


def test_a_memory_with_no_words_has_nothing_to_title(make_text_memory, client):
    rec = make_text_memory("alice", HIKE)
    get_repository().get_recording("alice", rec["id"]).transcript = ""

    assert _new_title(client, "alice", rec["id"]).status_code == 422


# -- the edit window ---------------------------------------------------------


def _age(uid: str, recording_id: str, **ago) -> None:
    """Move a memory's capture time into the past."""
    rec = get_repository().get_recording(uid, recording_id)
    rec.recorded_at = datetime.now(timezone.utc) - timedelta(**ago)


def test_the_profile_publishes_the_edit_window(client):
    """The app disables the controls itself, so it has to know the number."""
    assert client.get("/profile", headers=auth("alice")).json()["edit_window_days"] == 7


def test_editing_closes_seven_days_after_a_memory_is_saved(make_text_memory, client):
    rec = make_text_memory("alice", HIKE)
    _age("alice", rec["id"], days=7, minutes=1)

    renamed = _patch(client, "alice", rec["id"], title="Too late")
    reworded = _patch(client, "alice", rec["id"], transcript="Too late to say this.")
    retitled = _new_title(client, "alice", rec["id"])

    for resp in (renamed, reworded, retitled):
        assert resp.status_code == 403
        assert resp.json()["detail"] == {"error": "edit_window_closed", "window_days": 7}
    kept = client.get("/recordings", headers=auth("alice")).json()[0]
    assert kept["title"] == rec["title"]
    assert kept["transcript"] == HIKE
    assert kept["summary"] == rec["summary"]


def test_editing_is_still_open_on_the_seventh_day(make_text_memory, client):
    rec = make_text_memory("alice", HIKE)
    _age("alice", rec["id"], days=6, hours=23)

    assert _patch(client, "alice", rec["id"], title="Just in time").status_code == 200
    assert _new_title(client, "alice", rec["id"]).status_code == 200
    assert _patch(client, "alice", rec["id"], transcript="Still editable.").status_code == 200


def test_the_window_runs_from_when_it_was_saved_not_the_date_it_is_about(
    make_text_memory, client
):
    """A memory back-dated to last year was still written today."""
    rec = make_text_memory("alice", HIKE, event_date="2020-01-15")

    assert _patch(client, "alice", rec["id"], title="Long ago").status_code == 200


def test_starring_and_filing_stay_open_after_the_window(make_text_memory, client):
    """Organising is not editing."""
    rec = make_text_memory("alice", HIKE)
    _age("alice", rec["id"], days=30)
    journal = client.post("/journals", json={"name": "Travel"}, headers=auth("alice")).json()

    starred = _patch(client, "alice", rec["id"], is_milestone=True)
    filed = _patch(client, "alice", rec["id"], journal_id=journal["id"])

    assert starred.status_code == 200
    assert filed.status_code == 200
    assert filed.json()["journal_id"] == journal["id"]


def test_a_closed_memory_can_still_be_deleted(make_text_memory, client):
    rec = make_text_memory("alice", HIKE)
    _age("alice", rec["id"], days=30)

    assert client.delete(f"/recordings/{rec['id']}", headers=auth("alice")).status_code == 204
