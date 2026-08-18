"""Repository behaviour that doesn't need a live Firestore.

The Firestore implementation's network path can't run here, so the parts that
CAN be pinned down are: the document mapping (pure functions), the merge
semantics (exercised against the in-memory twin), and the fact that the two
implementations expose the same interface.
"""

from __future__ import annotations

import inspect
from datetime import date, datetime, timezone

import pytest

from app.models.feedback import Feedback
from app.models.journal import Journal
from app.models.recording import Chunk, Recording, RecordingStatus
from app.models.user import UserProfile, UserSettings, is_email, normalize_email
from app.services.firestore import (
    FirestoreRepository,
    Repository,
    chunks_to_doc,
    doc_to_chunks,
    doc_to_feedback,
    doc_to_recording,
    feedback_to_doc,
    recording_to_doc,
)


def make_recording(uid: str, rid: str = "r1", **kw) -> Recording:
    return Recording(
        id=rid,
        uid=uid,
        event_date=kw.pop("event_date", date(2026, 8, 16)),
        audio_path=f"gs://bucket/users/{uid}/audio/{rid}.m4a",
        status=RecordingStatus.indexed,
        title="Fishing trip with Dad",
        **kw,
    )


# -- interface parity ---------------------------------------------------


def test_both_repositories_expose_the_same_interface():
    """Guards against the Firestore implementation silently drifting.

    Tests run against the in-memory one, so a method added to `Repository` alone
    would look fine here and blow up only in production.
    """

    def public_methods(cls) -> dict[str, inspect.Signature]:
        return {
            name: inspect.signature(fn)
            for name, fn in inspect.getmembers(cls, inspect.isfunction)
            if not name.startswith("_")
        }

    memory = public_methods(Repository)
    firestore = public_methods(FirestoreRepository)

    assert memory.keys() == firestore.keys(), (
        f"only in-memory: {memory.keys() - firestore.keys()}; "
        f"only Firestore: {firestore.keys() - memory.keys()}"
    )
    for name, sig in memory.items():
        assert list(sig.parameters) == list(firestore[name].parameters), name


# -- document mapping ---------------------------------------------------


def test_recording_survives_a_document_round_trip():
    rec = make_recording("alice", duration_sec=12.5, tags=["lake"], is_milestone=True)
    back = doc_to_recording(recording_to_doc(rec))
    assert back == rec
    assert back.event_date == date(2026, 8, 16)
    assert back.recorded_at.tzinfo is not None


def test_recording_document_is_json_primitives_only():
    # Stored as ISO strings so Firestore's timestamps and Python's can't disagree.
    doc = recording_to_doc(make_recording("alice"))
    assert doc["event_date"] == "2026-08-16"
    assert isinstance(doc["recorded_at"], str)
    assert isinstance(doc["status"], str)


def test_all_chunks_live_in_one_document():
    chunks = [Chunk(id=f"c{i}", text=f"chunk {i}", embedding=[0.1, 0.2]) for i in range(5)]
    doc = chunks_to_doc(chunks)
    # One document, not five — a recall query reads one doc per recording.
    assert list(doc) == ["chunks"]
    assert len(doc["chunks"]) == 5
    assert doc_to_chunks(doc) == chunks


def test_missing_chunk_document_reads_as_empty():
    assert doc_to_chunks(None) == []
    assert doc_to_chunks({}) == []


def test_feedback_survives_a_document_round_trip():
    item = Feedback(id="f1", uid="alice", kind="problem", message="broke")
    assert doc_to_feedback(feedback_to_doc(item)) == item


# -- email helpers ------------------------------------------------------


@pytest.mark.parametrize("value", ["a@b.com", "First.Last+tag@sub.example.co.uk"])
def test_accepts_real_addresses(value):
    assert is_email(value)


@pytest.mark.parametrize("value", ["", "nope", "a@b", "a b@c.com", "@b.com", "a@@b.com"])
def test_rejects_malformed_addresses(value):
    assert not is_email(value)


def test_email_index_key_is_case_and_space_insensitive():
    assert normalize_email("  Prakash@Example.COM ") == "prakash@example.com"


# -- profile / email index ----------------------------------------------


def test_profile_starts_absent_and_round_trips():
    repo = Repository()
    assert repo.get_profile("alice") is None

    saved = repo.save_profile("alice", UserProfile(preferred_name="Prakash", email="p@x.com"))
    assert repo.get_profile("alice") == saved


def test_has_profile_requires_a_verified_email():
    assert not UserProfile().has_profile
    assert not UserProfile(email="p@x.com").has_profile
    assert UserProfile(email="p@x.com", email_verified=True).has_profile


def test_email_index_lookup_ignores_case():
    repo = Repository()
    repo.set_email_index("Prakash@Example.com", "alice")
    assert repo.uid_for_email("prakash@example.com") == "alice"
    assert repo.uid_for_email("nobody@example.com") is None


# -- merge --------------------------------------------------------------


def test_merge_moves_recordings_and_rewrites_the_denormalized_uid():
    repo = Repository()
    repo.add_recording(make_recording("throwaway", "r1"))
    repo.save_chunks("throwaway", "r1", [Chunk(id="c1", text="hi", embedding=[1.0])])
    repo.add_recording(make_recording("account", "r2"))

    moved = repo.merge_user("throwaway", "account")

    assert moved["recordings"] == 1
    assert {r.id for r in repo.list_recordings("account")} == {"r1", "r2"}
    assert repo.list_recordings("throwaway") == []

    moved_rec = repo.get_recording("account", "r1")
    assert moved_rec is not None
    assert moved_rec.uid == "account", "uid is stored on the document, not just the bucket"


def test_merge_keeps_chunks_reachable_for_recall():
    repo = Repository()
    repo.add_recording(make_recording("throwaway", "r1"))
    repo.save_chunks("throwaway", "r1", [Chunk(id="c1", text="lake", embedding=[1.0, 0.0])])

    repo.merge_user("throwaway", "account")

    hits = repo.vector_search("account", [1.0, 0.0], top_k=5)
    assert [h.chunk.text for h in hits] == ["lake"]
    assert repo.vector_search("throwaway", [1.0, 0.0], top_k=5) == []


def test_merge_rewrites_feedback_uid_too():
    repo = Repository()
    repo.add_feedback(Feedback(id="f1", uid="throwaway", kind="problem", message="broke"))

    repo.merge_user("throwaway", "account")

    listed = repo.list_feedback("account")
    assert [f.id for f in listed] == ["f1"]
    assert listed[0].uid == "account"
    assert repo.list_feedback("throwaway") == []


def test_merge_keeps_the_accounts_own_settings():
    repo = Repository()
    repo.save_settings_doc("account", UserSettings(answer_language="ta"))
    repo.save_settings_doc("throwaway", UserSettings(answer_language="fr"))

    repo.merge_user("throwaway", "account")

    assert repo.get_settings_doc("account").answer_language == "ta"


def test_merging_a_uid_into_itself_is_a_no_op():
    repo = Repository()
    repo.add_recording(make_recording("alice", "r1"))

    assert repo.merge_user("alice", "alice") == {
        "recordings": 0,
        "journals": 0,
        "feedback": 0,
        "insights": 0,
        "feeds": 0,
    }
    assert len(repo.list_recordings("alice")) == 1


def test_merge_leaves_other_users_untouched():
    repo = Repository()
    repo.add_recording(make_recording("throwaway", "r1"))
    repo.add_recording(make_recording("bystander", "r9"))

    repo.merge_user("throwaway", "account")

    assert {r.id for r in repo.list_recordings("bystander")} == {"r9"}
    assert repo.list_recordings("account")[0].id == "r1"


# -- deletion -----------------------------------------------------------


def test_deleting_an_account_frees_its_email_for_reuse():
    repo = Repository()
    repo.save_profile("alice", UserProfile(email="p@x.com", email_verified=True))
    repo.set_email_index("p@x.com", "alice")

    repo.delete_user("alice")

    assert repo.uid_for_email("p@x.com") is None
    assert repo.get_profile("alice") is None


def test_recordings_stay_scoped_to_their_owner():
    repo = Repository()
    repo.add_recording(make_recording("alice", "r1"))
    repo.save_chunks("alice", "r1", [Chunk(id="c1", text="secret", embedding=[1.0])])

    assert repo.list_recordings("bob") == []
    assert repo.get_recording("bob", "r1") is None
    assert repo.vector_search("bob", [1.0], top_k=5) == []


def test_recorded_at_ordering_survives_iso_string_storage():
    """Documents store ISO strings; they must still sort newest-first."""
    repo = Repository()
    for i, hour in enumerate([8, 12, 10]):
        rec = make_recording("alice", f"r{i}")
        rec.recorded_at = datetime(2026, 8, 16, hour, tzinfo=timezone.utc)
        repo.add_recording(rec)

    listed = repo.list_recordings("alice")
    assert [r.recorded_at.hour for r in listed] == [12, 10, 8]


# -- journals ------------------------------------------------------------


def test_journals_survive_a_restore_still_holding_their_memories():
    """Restore-after-reinstall must bring the filing back, not just the files.

    `journal_id` is denormalized onto each recording, so a merge that moved the
    recordings but left the journals behind would return every memory pointing
    at a container that no longer exists — filed, and yet in nothing.
    """
    repo = Repository()
    repo.save_journal("account", Journal(id="j1", name="Travel"))
    repo.add_recording(make_recording("account", "r1", journal_id="j1"))

    moved = repo.merge_user("account", "throwaway")

    assert moved["journals"] == 1
    assert [j.name for j in repo.list_journals("throwaway")] == ["Travel"]
    assert repo.list_journals("account") == []
    assert repo.list_recordings("throwaway", journal_id="j1")[0].id == "r1"


def test_deleting_an_account_purges_its_journals():
    repo = Repository()
    repo.save_journal("alice", Journal(id="j1", name="Travel"))

    repo.delete_user("alice")

    assert repo.list_journals("alice") == []


def test_journals_stay_scoped_to_their_owner():
    repo = Repository()
    repo.save_journal("alice", Journal(id="j1", name="Travel"))

    assert repo.list_journals("bob") == []
    assert repo.get_journal("bob", "j1") is None


def test_an_empty_journal_filter_selects_only_unfiled_recordings():
    """`""` means unfiled; `None` means no filter. Collapsing them would make
    the Unfiled view — the only route to the pre-journals backlog — impossible."""
    repo = Repository()
    repo.add_recording(make_recording("alice", "filed", journal_id="j1"))
    repo.add_recording(make_recording("alice", "loose"))

    assert {r.id for r in repo.list_recordings("alice")} == {"filed", "loose"}
    assert [r.id for r in repo.list_recordings("alice", journal_id="")] == ["loose"]
    assert [r.id for r in repo.list_recordings("alice", journal_id="j1")] == ["filed"]


def test_deleting_a_journal_unfiles_without_deleting():
    repo = Repository()
    repo.save_journal("alice", Journal(id="j1", name="Travel"))
    repo.add_recording(make_recording("alice", "r1", journal_id="j1"))
    repo.add_recording(make_recording("alice", "r2", journal_id="j1"))
    repo.add_recording(make_recording("alice", "r3"))

    assert repo.delete_journal("alice", "j1") == 2
    assert repo.get_journal("alice", "j1") is None
    assert len(repo.list_recordings("alice")) == 3
    assert {r.journal_id for r in repo.list_recordings("alice")} == {""}
