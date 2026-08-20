"""Deleting a memory, and deleting an account.

The app tells the user, in as many words, that nothing survives a delete and that
we cannot get it back. That sentence is a promise about *every* place a memory's
words end up, not just the row it was read from — so these tests go looking for
the leaks:

* the audio object, which outlives the metadata unless it is deleted explicitly;
* the chunks the search index is built from, which would keep answering questions
  about a memory that no longer exists;
* the **derived caches** — the On This Day feed and the insight cache — both of
  which copy a title and a summary out of the recording they were built from, and
  both of which are served from storage rather than recomputed.

The last one is the reason this file exists. A deleted memory reading back to the
person who deleted it is the worst outcome the feature has, and it is invisible
from the endpoint's own response.
"""

from __future__ import annotations

from datetime import date, timedelta

import pytest

from app.services.firestore import get_repository
from tests.conftest import auth


def _upload(client, uid: str) -> str:
    return client.post("/uploads", json={}, headers=auth(uid)).json()["audio_path"]


def _record(client, uid: str, transcript: str, event_date: str | None = None) -> dict:
    audio_path = _upload(client, uid)
    client.post(
        "/dev/seed-transcript",
        json={"audio_path": audio_path, "transcript": transcript, "language": "en"},
        headers=auth(uid),
    )
    payload = {"audio_path": audio_path, "duration_sec": 5.0}
    if event_date:
        payload["event_date"] = event_date
    resp = client.post("/recordings", json=payload, headers=auth(uid))
    assert resp.status_code == 201, resp.text
    return resp.json()


def _record_with_audio(client, uid: str, transcript: str) -> dict:
    """As `_record`, but with bytes actually PUT to the (mock) bucket, so there is
    a real object for the delete to have to remove."""
    up = client.post("/uploads", json={}, headers=auth(uid)).json()
    client.put(up["upload_url"], content=b"\x00\x01" * 512, headers=up["headers"])
    client.post(
        "/dev/seed-transcript",
        json={"audio_path": up["audio_path"], "transcript": transcript, "language": "en"},
        headers=auth(uid),
    )
    resp = client.post(
        "/recordings",
        json={"audio_path": up["audio_path"], "duration_sec": 5.0},
        headers=auth(uid),
    )
    assert resp.status_code == 201, resp.text
    return resp.json()


def _ask(client, uid: str, question: str) -> dict:
    return client.post("/chat", json={"question": question}, headers=auth(uid)).json()


# -- one memory ---------------------------------------------------------


def test_deleting_removes_the_row(client):
    made = _record(client, "alice", "We adopted a golden retriever named Max.")

    assert client.delete(f"/recordings/{made['id']}", headers=auth("alice")).status_code == 204

    assert client.get("/recordings", headers=auth("alice")).json() == []
    assert client.get(f"/recordings/{made['id']}", headers=auth("alice")).status_code == 404


def test_deleting_takes_the_audio_with_it(client):
    """The blob is addressed only by the metadata, so a delete that forgets it
    leaves audio nobody can reach and the user believes is gone.

    Uploads real bytes rather than just registering a path: without them there is
    nothing to fail to delete, and the test would pass against a delete that
    never touched storage at all.
    """
    made = _record_with_audio(client, "alice", "Something spoken.")
    assert client.get(f"/recordings/{made['id']}/audio", headers=auth("alice")).status_code == 200

    client.delete(f"/recordings/{made['id']}", headers=auth("alice"))

    from app.services.storage import get_storage

    assert not get_storage().read_bytes(made["audio_path"])


def test_deleting_removes_it_from_recall(client):
    """The chunks are the search index. Left behind, the AI goes on answering
    questions from a memory its owner deleted."""
    made = _record(client, "alice", "We adopted a golden retriever named Max.")
    assert _ask(client, "alice", "What did we name the dog?")["citations"]

    client.delete(f"/recordings/{made['id']}", headers=auth("alice"))

    assert _ask(client, "alice", "What did we name the dog?")["citations"] == []


def test_deleting_clears_the_on_this_day_cache(client):
    """A feed item copies the title and summary out of the recording, and the feed
    is *served from storage*. Without a purge the home screen keeps showing a
    memory that no longer exists anywhere else."""
    a_year_ago = date.today().replace(year=date.today().year - 1)
    made = _record(client, "alice", "The day we moved in.", event_date=a_year_ago.isoformat())

    feed = client.get("/memories/on-this-day", headers=auth("alice")).json()
    assert [i["recording_id"] for i in feed["items"]] == [made["id"]]
    # Cached, not recomputed — which is precisely what makes it dangerous.
    assert get_repository().get_feed("alice", date.today()) is not None

    client.delete(f"/recordings/{made['id']}", headers=auth("alice"))

    after = client.get("/memories/on-this-day", headers=auth("alice")).json()
    assert after["items"] == []


def test_deleting_clears_the_insight_cache(client):
    """An insight is a narrative written over a range of memories and cached by
    range. Same leak as the feed, on a longer horizon."""
    made = _record(client, "alice", "A quiet week of long walks.")
    body = {"range": "month"}
    first = client.post("/insights", json=body, headers=auth("alice")).json()
    assert first["recording_count"] == 1
    assert get_repository().get_cached_insight("alice", first["id"]) is not None

    client.delete(f"/recordings/{made['id']}", headers=auth("alice"))

    again = client.post("/insights", json=body, headers=auth("alice")).json()
    assert again["recording_count"] == 0


def test_deleting_one_memory_leaves_the_others(client):
    """The derived caches are purged wholesale, so this checks the blast radius
    stops at the cache: the *memories* themselves must be untouched."""
    keep = _record(client, "alice", "A ridge walk at sunrise.")
    drop = _record(client, "alice", "An ordinary Tuesday.")

    client.delete(f"/recordings/{drop['id']}", headers=auth("alice"))

    remaining = client.get("/recordings", headers=auth("alice")).json()
    assert [r["id"] for r in remaining] == [keep["id"]]
    assert _ask(client, "alice", "What did I do at sunrise?")["citations"]


def test_you_cannot_delete_someone_elses_memory(client):
    made = _record(client, "alice", "Mine alone.")

    assert client.delete(f"/recordings/{made['id']}", headers=auth("bob")).status_code == 404

    assert len(client.get("/recordings", headers=auth("alice")).json()) == 1


def test_deleting_twice_is_a_404_not_a_500(client):
    """The app treats the second one as success — the memory is gone either way —
    but the API still has to answer it honestly rather than fall over."""
    made = _record(client, "alice", "Once.")
    assert client.delete(f"/recordings/{made['id']}", headers=auth("alice")).status_code == 204
    assert client.delete(f"/recordings/{made['id']}", headers=auth("alice")).status_code == 404


# -- the whole account --------------------------------------------------


def test_deleting_the_account_leaves_nothing_behind(client):
    """Everything the account touched, in one pass. Enumerated rather than spot-
    checked, because the failure mode is one collection quietly missed."""
    yesterday = (date.today() - timedelta(days=1)).isoformat()
    _record(client, "alice", "A ridge walk at sunrise.", event_date=yesterday)
    journal = client.post("/journals", json={"name": "Travel"}, headers=auth("alice")).json()
    client.post(
        "/recordings/text",
        json={"text": "Written down instead.", "journal_id": journal["id"]},
        headers=auth("alice"),
    )
    client.post("/insights", json={"range": "month"}, headers=auth("alice"))
    client.get("/memories/on-this-day", headers=auth("alice"))
    client.post("/feedback", json={"message": "Nice app."}, headers=auth("alice"))
    client.put("/settings", json={"answer_language": "ta"}, headers=auth("alice"))

    assert client.delete("/account", headers=auth("alice")).status_code == 204

    repo = get_repository()
    assert client.get("/recordings", headers=auth("alice")).json() == []
    assert client.get("/journals", headers=auth("alice")).json() == []
    assert _ask(client, "alice", "what happened at sunrise?")["citations"] == []
    assert repo.get_feed("alice", date.today()) is None
    assert repo.list_feedback("alice") == []
    assert repo.get_user_stats("alice") is None
    assert repo.get_profile("alice") is None


def test_deleting_the_account_takes_the_audio_with_it(client):
    """By prefix, so it also sweeps up blobs whose recording was never registered
    — an upload URL issued to a client that then crashed."""
    made = _record_with_audio(client, "alice", "Something spoken.")
    orphan = client.post("/uploads", json={}, headers=auth("alice")).json()
    client.put(orphan["upload_url"], content=b"\x02\x03" * 256, headers=orphan["headers"])

    client.delete("/account", headers=auth("alice"))

    from app.services.storage import get_storage

    assert not get_storage().read_bytes(made["audio_path"])
    assert not get_storage().read_bytes(orphan["audio_path"])


def test_deleting_one_account_does_not_touch_another(client):
    _record(client, "alice", "A ridge walk at sunrise.")
    bobs = _record(client, "bob", "We adopted a golden retriever named Max.")

    client.delete("/account", headers=auth("alice"))

    still_there = client.get("/recordings", headers=auth("bob")).json()
    assert [r["id"] for r in still_there] == [bobs["id"]]
    assert _ask(client, "bob", "What did we name the dog?")["citations"]


# -- losing a race with the ingestion worker ----------------------------
#
# The leak these cover was found on production, not here, and the reason is worth
# stating: mock mode runs ingestion **inline and synchronously** inside the create
# request, so offline there is no window between reading a recording and writing
# it back. In real mode that window is a Pub/Sub round trip and several seconds of
# Gemini, and a delete landing inside it used to be silently undone — the worker's
# final write re-created the document, transcript, summary and search index
# included.
#
# So these tests manufacture the window: `enrich` is made to perform the user's
# delete as a side effect, which puts the delete exactly where production put it —
# after the run started, before it writes back.


def _delete_during_enrich(monkeypatch, deleter):
    """Run `deleter()` inside enrichment, i.e. mid-ingestion.

    Wraps the real implementation rather than replacing it, so the run still
    produces genuine chunks and a genuine status change and reaches its write-back
    the ordinary way.
    """
    from app.services.gemini import GeminiService

    original = GeminiService.enrich

    def enrich_then_delete(self, transcript, language, answer_language):
        result = original(self, transcript, language, answer_language)
        deleter()
        return result

    monkeypatch.setattr(GeminiService, "enrich", enrich_then_delete)


def test_a_delete_during_ingestion_is_not_undone(client, monkeypatch):
    """The bug, reproduced. The worker must not write back a memory that is gone."""
    from app.pipeline.ingest import RecordingNotFound, process_recording

    made = _record(client, "alice", "We adopted a golden retriever named Max.")
    repo = get_repository()
    _delete_during_enrich(monkeypatch, lambda: repo.delete_recording("alice", made["id"]))

    # A re-run, which is also the at-least-once case: same message, second go.
    with pytest.raises(RecordingNotFound):
        process_recording("alice", made["id"])

    assert client.get("/recordings", headers=auth("alice")).json() == []
    assert client.get(f"/recordings/{made['id']}", headers=auth("alice")).status_code == 404
    assert _ask(client, "alice", "What did we name the dog?")["citations"] == []


def test_the_chunks_that_run_wrote_are_discarded_too(client, monkeypatch):
    """The chunks hold the transcript, and this run writes them *before* it learns
    the recording is gone. Asserted against the store directly, because residue
    under a deleted recording is by definition unreachable through the API — which
    is exactly what would let it sit there unnoticed."""
    from app.pipeline.ingest import RecordingNotFound, process_recording

    made = _record(client, "alice", "We adopted a golden retriever named Max.")
    repo = get_repository()
    assert repo._chunks.get(made["id"]), "precondition: the first run indexed it"

    _delete_during_enrich(monkeypatch, lambda: repo.delete_recording("alice", made["id"]))
    with pytest.raises(RecordingNotFound):
        process_recording("alice", made["id"])

    assert not repo._chunks.get(made["id"]), "the transcript must not survive in the index"


def test_an_account_purge_during_ingestion_is_not_undone(client, monkeypatch):
    """The same race, one size up — this is the one that was caught on production."""
    from app.pipeline.ingest import RecordingNotFound, process_recording

    made = _record(client, "alice", "A ridge walk at sunrise.")
    _delete_during_enrich(
        monkeypatch, lambda: client.delete("/account", headers=auth("alice"))
    )

    with pytest.raises(RecordingNotFound):
        process_recording("alice", made["id"])

    assert client.get("/recordings", headers=auth("alice")).json() == []
    assert get_repository().get_profile("alice") is None


def test_a_redelivered_message_long_after_a_delete_finds_nothing(client):
    """Pub/Sub is at-least-once with no dead-letter policy, so the same message can
    arrive days later. It must not rebuild the memory it names."""
    from app.pipeline.ingest import RecordingNotFound, process_recording

    made = _record(client, "alice", "Once indexed, then deleted.")
    client.delete(f"/recordings/{made['id']}", headers=auth("alice"))

    with pytest.raises(RecordingNotFound):
        process_recording("alice", made["id"])

    assert client.get("/recordings", headers=auth("alice")).json() == []


def test_update_recording_never_creates(client):
    """The structural guarantee the fix rests on. `add_recording` is the only way a
    recording comes into being; an update to something absent is a no-op, not an
    upsert, so no slow writer anywhere can resurrect a deleted memory."""
    from datetime import date as _date

    from app.models.recording import Recording

    repo = get_repository()
    orphan = Recording(
        id="never-added",
        uid="alice",
        event_date=_date.today(),
        transcript="Should not come into being this way.",
    )

    assert repo.update_recording(orphan) is None
    assert repo.get_recording("alice", "never-added") is None
    assert client.get("/recordings", headers=auth("alice")).json() == []


def test_starring_an_already_deleted_memory_is_a_404(client):
    """Two devices: one deletes, the other stars. Caught by the read at the top of
    the handler — the easy half of the case below."""
    made = _record(client, "alice", "Worth remembering.")
    client.delete(f"/recordings/{made['id']}", headers=auth("alice"))

    resp = client.patch(
        f"/recordings/{made['id']}", json={"is_milestone": True}, headers=auth("alice")
    )

    assert resp.status_code == 404
    assert client.get("/recordings", headers=auth("alice")).json() == []


def test_starring_cannot_resurrect_a_memory_deleted_mid_request(client, monkeypatch):
    """The hard half: the delete lands *between* the handler's read and its write.

    `PATCH` is a read-modify-write like ingestion is, just a much faster one, so
    it had the same hole — an upserting `update_recording` would write the starred
    copy back and the memory would reappear, now flagged as a milestone. The
    window is microseconds in practice, which is exactly why it needs a test
    rather than a hope: this one holds it open on purpose.
    """
    made = _record(client, "alice", "Worth remembering.")
    repo = get_repository()
    read = repo.get_recording

    def read_then_delete(uid, recording_id):
        rec = read(uid, recording_id)
        if rec is not None:
            repo.delete_recording(uid, recording_id)  # the other device, mid-request
        return rec

    monkeypatch.setattr(repo, "get_recording", read_then_delete)

    resp = client.patch(
        f"/recordings/{made['id']}", json={"is_milestone": True}, headers=auth("alice")
    )

    assert resp.status_code == 404
    monkeypatch.undo()
    assert client.get("/recordings", headers=auth("alice")).json() == []


def test_the_email_is_released_so_the_address_can_sign_up_again(client):
    """The email index is what makes a restore find the old account. Left behind,
    the address is permanently claimed by an account that no longer exists."""
    email = "someone@example.com"
    client.post("/auth/otp/request", json={"email": email}, headers=auth("alice"))
    code = client.post("/dev/last-otp", json={"email": email}, headers=auth("alice")).json()["code"]
    client.post("/auth/otp/verify", json={"email": email, "code": code}, headers=auth("alice"))
    assert client.get("/profile", headers=auth("alice")).json()["email_verified"] is True

    client.delete("/account", headers=auth("alice"))

    client.post("/auth/otp/request", json={"email": email}, headers=auth("carol"))
    code = client.post("/dev/last-otp", json={"email": email}, headers=auth("carol")).json()["code"]
    verified = client.post(
        "/auth/otp/verify", json={"email": email, "code": code}, headers=auth("carol")
    ).json()
    # A fresh signup, not a restore of the deleted account.
    assert verified["status"] == "signed_up"
    assert client.get("/recordings", headers=auth("carol")).json() == []
