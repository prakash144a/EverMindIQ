"""Per-user counters: do they move, and do they survive the awkward paths.

The counters are denormalized precisely so the console never has to walk every
user's recordings. That only pays off if they stay correct through deletion,
account merges, and purges — which is what this file pins down.
"""

from datetime import datetime, timedelta, timezone

from app.models.recording import Recording, RecordingStatus
from app.models.user import UserTier
from app.services import stats as stats_ops
from app.services.firestore import Repository, get_repository
from tests.conftest import admin_auth, auth


def _record(client, uid: str, duration: float) -> dict:
    up = client.post("/uploads", json={}, headers=auth(uid)).json()
    return client.post(
        "/recordings",
        json={"audio_path": up["audio_path"], "duration_sec": duration},
        headers=auth(uid),
    ).json()


def _stats(uid: str):
    return get_repository().get_user_stats(uid)


def _make_recording(uid: str, rid: str, duration: float) -> Recording:
    return Recording(
        id=rid,
        uid=uid,
        event_date=datetime.now(timezone.utc).date(),
        audio_path=f"gs://b/users/{uid}/audio/{rid}.m4a",
        duration_sec=duration,
        status=RecordingStatus.indexed,
    )


# -- create / delete ----------------------------------------------------


def test_creating_recordings_accumulates_counters(client):
    _record(client, "alice", 12.0)
    _record(client, "alice", 30.0)

    stats = _stats("alice")
    assert stats.recordings_count == 2
    assert stats.total_duration_sec == 42.0
    assert stats.max_duration_sec == 30.0
    assert stats.first_recorded_at is not None
    assert stats.last_recording_at is not None


def test_counters_are_scoped_to_their_owner(client):
    _record(client, "alice", 12.0)
    _record(client, "bob", 99.0)

    assert _stats("alice").recordings_count == 1
    assert _stats("alice").max_duration_sec == 12.0
    assert _stats("bob").max_duration_sec == 99.0


def test_deleting_decrements_the_count_but_not_the_maximum(client):
    """Encodes a deliberate decision, so it cannot be "fixed" by accident.

    A maximum cannot be decremented without rescanning every remaining
    recording — an O(N) read per delete. So it means "the longest recording this
    account has ever made", which is also the more useful answer to "how long do
    people expect to record for".
    """
    short = _record(client, "alice", 10.0)
    _record(client, "alice", 300.0)
    long_one = _record(client, "alice", 300.0)

    assert client.delete(f"/recordings/{long_one['id']}", headers=auth("alice")).status_code == 204

    stats = _stats("alice")
    assert stats.recordings_count == 2
    assert stats.total_duration_sec == 310.0
    assert stats.max_duration_sec == 300.0, "high-water mark survives the delete"
    assert short["id"]


def test_recompute_lowers_a_stale_high_water_mark(client):
    """The escape hatch for the invariant above."""
    _record(client, "alice", 10.0)
    long_one = _record(client, "alice", 300.0)
    client.delete(f"/recordings/{long_one['id']}", headers=auth("alice"))

    r = client.post("/admin/users/alice/recompute-stats", headers=admin_auth())
    assert r.status_code == 200
    assert r.json()["max_duration_sec"] == 10.0
    assert r.json()["recordings_count"] == 1


def test_deleting_never_drives_counters_negative(client):
    rec = _record(client, "alice", 10.0)
    client.delete(f"/recordings/{rec['id']}", headers=auth("alice"))
    client.delete(f"/recordings/{rec['id']}", headers=auth("alice"))  # already gone

    stats = _stats("alice")
    assert stats.recordings_count == 0
    assert stats.total_duration_sec == 0.0


def test_feedback_is_counted(client):
    client.post("/feedback", json={"kind": "idea", "message": "add export"}, headers=auth("alice"))
    assert _stats("alice").feedback_count == 1


# -- merge --------------------------------------------------------------
#
# `merge_user(src, dst)` is called by the OTP restore path as
# `merge_user(account_uid, session_uid)` — src is the long-lived ACCOUNT and dst
# is the fresh anonymous session. These tests exist because that direction is
# the opposite of the intuitive reading, and getting it wrong corrupts data
# permanently while looking fine in ordinary use.


def test_merge_folds_the_accounts_counters_onto_the_session():
    repo = Repository()
    account, _ = repo.ensure_user_stats("account")
    stats_ops.apply_recording_created(account, 120.0)
    stats_ops.apply_recording_created(account, 20.0)
    repo.save_user_stats(account)

    session, _ = repo.ensure_user_stats("session")
    stats_ops.apply_recording_created(session, 5.0)
    repo.save_user_stats(session)

    repo.merge_user("account", "session")

    merged = repo.get_user_stats("session")
    assert merged.recordings_count == 3
    assert merged.total_duration_sec == 145.0
    assert merged.max_duration_sec == 120.0
    assert repo.get_user_stats("account") is None


def test_merge_keeps_the_older_signup_date():
    """Otherwise every sign-in resets the account's age to today."""
    repo = Repository()
    old = datetime.now(timezone.utc) - timedelta(days=400)

    account, _ = repo.ensure_user_stats("account")
    account.created_at = old
    account.signup_day = old.date()
    repo.save_user_stats(account)
    repo.ensure_user_stats("session")

    repo.merge_user("account", "session")

    merged = repo.get_user_stats("session")
    assert merged.created_at == old
    assert merged.signup_day == old.date()


def test_merge_never_downgrades_a_premium_account():
    """The costliest way to get the merge direction wrong: signing back in
    would silently revoke what the user paid for."""
    repo = Repository()
    account, _ = repo.ensure_user_stats("account")
    account.tier = UserTier.premium
    repo.save_user_stats(account)
    repo.ensure_user_stats("session")  # a fresh anonymous session, free by default

    repo.merge_user("account", "session")

    assert repo.get_user_stats("session").tier == UserTier.premium


def test_merge_preserves_the_old_uid_as_lineage():
    """The source uid is deleted by the merge, so this is the only remaining
    record that the account previously existed under it."""
    repo = Repository()
    repo.ensure_user_stats("account")
    repo.ensure_user_stats("session")

    repo.merge_user("account", "session")

    assert repo.get_user_stats("session").previous_uids == ["account"]


def test_merging_into_itself_changes_nothing():
    repo = Repository()
    stats, _ = repo.ensure_user_stats("alice")
    stats_ops.apply_recording_created(stats, 10.0)
    repo.save_user_stats(stats)

    repo.merge_user("alice", "alice")

    assert repo.get_user_stats("alice").recordings_count == 1
    assert repo.get_user_stats("alice").previous_uids == []


# -- purge --------------------------------------------------------------


def test_account_purge_removes_the_stats_record(client):
    _record(client, "alice", 10.0)
    assert _stats("alice") is not None

    assert client.delete("/account", headers=auth("alice")).status_code == 204

    assert _stats("alice") is None


def test_recompute_rebuilds_from_the_recordings_themselves():
    repo = Repository()
    repo.ensure_user_stats("alice")
    for i, duration in enumerate([5.0, 45.0, 12.0]):
        repo.add_recording(_make_recording("alice", f"r{i}", duration))

    stats = repo.recompute_user_stats("alice")

    assert stats.recordings_count == 3
    assert stats.total_duration_sec == 62.0
    assert stats.max_duration_sec == 45.0
