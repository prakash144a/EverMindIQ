"""The recording entitlements: how long one may be, and how many a month buys.

Two limits with deliberately different characters, and the difference is what
most of this file pins down:

* **Length** is a property of the thing being created, so it is checked against
  the recording in hand and answered with 413.
* **The monthly quota** is a property of the account's spending, so it is checked
  against a counter, answered with 429, and — unlike every other counter in
  `UserStats` — is *not* given back when a recording is deleted.

Typed memories are metered by neither. That is the point of `text_max_chars`
existing separately, and it is asserted here rather than left to be rediscovered.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from app.core.config import get_settings
from app.services import stats as stats_ops
from app.services.firestore import get_repository
from tests.conftest import auth, set_tier


def _upload(client, uid: str) -> str:
    return client.post("/uploads", json={}, headers=auth(uid)).json()["audio_path"]


def _record(client, uid: str, duration: float):
    return client.post(
        "/recordings",
        json={"audio_path": _upload(client, uid), "duration_sec": duration},
        headers=auth(uid),
    )


def _profile(client, uid: str) -> dict:
    return client.get("/profile", headers=auth(uid)).json()


# -- how long one recording may be --------------------------------------


def test_free_gets_a_minute(client):
    assert _record(client, "alice", 60.0).status_code == 201


def test_free_is_refused_a_longer_one(client):
    resp = _record(client, "alice", 95.0)
    assert resp.status_code == 413
    detail = resp.json()["detail"]
    assert detail["error"] == "recording_too_long"
    assert detail["limit_sec"] == 60
    assert detail["tier"] == "free"


def test_a_second_of_measurement_slack_is_forgiven(client):
    """The app stops the recorder at the limit but times it with a wall clock, so
    an honest 60-second recording reports a little over. Rejecting that would
    read as a bug in the recorder."""
    assert _record(client, "alice", 60.6).status_code == 201


def test_premium_gets_ten_minutes(client):
    set_tier("alice", "premium")
    assert _record(client, "alice", 600.0).status_code == 201
    assert _record(client, "alice", 640.0).status_code == 413


def test_a_refused_recording_is_not_stored(client):
    """The 413 has to be a real refusal, not a label on a memory we kept anyway."""
    _record(client, "alice", 300.0)
    assert client.get("/recordings", headers=auth("alice")).json() == []


# -- how many a month --------------------------------------------------


def test_free_runs_out_after_its_allowance(client, monkeypatch):
    monkeypatch.setattr(get_settings(), "recordings_per_month_free", 3)

    for _ in range(3):
        assert _record(client, "alice", 5.0).status_code == 201

    resp = _record(client, "alice", 5.0)
    assert resp.status_code == 429
    detail = resp.json()["detail"]
    assert detail["error"] == "recording_quota"
    assert (detail["limit"], detail["used"], detail["tier"]) == (3, 3, "free")
    assert detail["resets_on"] == stats_ops.month_resets_on().isoformat()


def test_the_quota_is_per_account(client, monkeypatch):
    monkeypatch.setattr(get_settings(), "recordings_per_month_free", 1)
    assert _record(client, "alice", 5.0).status_code == 201
    assert _record(client, "alice", 5.0).status_code == 429
    assert _record(client, "bob", 5.0).status_code == 201


def test_premium_raises_the_ceiling(client, monkeypatch):
    monkeypatch.setattr(get_settings(), "recordings_per_month_free", 1)
    monkeypatch.setattr(get_settings(), "recordings_per_month_premium", 4)

    assert _record(client, "alice", 5.0).status_code == 201
    assert _record(client, "alice", 5.0).status_code == 429

    set_tier("alice", "premium")
    for _ in range(3):
        assert _record(client, "alice", 5.0).status_code == 201
    assert _record(client, "alice", 5.0).status_code == 429


def test_deleting_does_not_hand_the_slot_back(client, monkeypatch):
    """Unlike `recordings_count`, the meter measures what the month has spent.
    The transcription was already paid for, so refunding the slot would make the
    quota bypassable by recording, keeping the transcript, and deleting."""
    monkeypatch.setattr(get_settings(), "recordings_per_month_free", 1)

    made = _record(client, "alice", 5.0).json()
    assert client.delete(f"/recordings/{made['id']}", headers=auth("alice")).status_code == 204

    assert _record(client, "alice", 5.0).status_code == 429


def test_a_new_month_starts_fresh(client, monkeypatch):
    monkeypatch.setattr(get_settings(), "recordings_per_month_free", 1)
    assert _record(client, "alice", 5.0).status_code == 201
    assert _record(client, "alice", 5.0).status_code == 429

    # Age the meter rather than the clock: a counter stamped with a month that is
    # no longer the current one reads as zero, which *is* the roll-over.
    repo = get_repository()
    stats = repo.get_user_stats("alice")
    last_month = datetime.now(timezone.utc).replace(day=1) - timedelta(days=1)
    stats.usage_month = stats_ops.month_key(last_month)
    repo.save_user_stats(stats)

    assert _record(client, "alice", 5.0).status_code == 201
    assert repo.get_user_stats("alice").voice_recordings_this_month == 1


def test_back_dating_does_not_buy_another_month(client, monkeypatch):
    """The meter follows when the recording was *created*, not when the moment it
    describes happened — otherwise every past month would carry its own quota."""
    monkeypatch.setattr(get_settings(), "recordings_per_month_free", 1)

    resp = client.post(
        "/recordings",
        json={
            "audio_path": _upload(client, "alice"),
            "duration_sec": 5.0,
            "event_date": "2019-04-02",
        },
        headers=auth("alice"),
    )
    assert resp.status_code == 201
    assert _record(client, "alice", 5.0).status_code == 429


# -- typed memories are metered by neither ------------------------------


def test_typing_is_not_charged_to_the_voice_quota(client, monkeypatch, make_text_memory):
    monkeypatch.setattr(get_settings(), "recordings_per_month_free", 1)
    assert _record(client, "alice", 5.0).status_code == 201
    assert _record(client, "alice", 5.0).status_code == 429

    make_text_memory("alice", "Typed, and it still costs nothing to transcribe.")
    make_text_memory("alice", "Twice over.")

    assert get_repository().get_user_stats("alice").voice_recordings_this_month == 1
    assert len(client.get("/recordings", headers=auth("alice")).json()) == 3


# -- what the app is told ----------------------------------------------


def test_the_profile_carries_the_limits_and_the_usage(client):
    """The app has to stop someone before they speak. Learning the quota from a
    429 after the audio is uploaded means their words were recorded for nothing."""
    body = _profile(client, "alice")
    assert body["recordings_per_month"] == 10
    assert body["recording_max_sec"] == 60
    assert body["voice_session_max_sec"] == 600
    assert body["recordings_used_this_month"] == 0
    assert body["recordings_month_resets_on"] == stats_ops.month_resets_on().isoformat()

    _record(client, "alice", 5.0)
    assert _profile(client, "alice")["recordings_used_this_month"] == 1


def test_premium_sees_its_own_numbers(client):
    set_tier("alice", "premium")
    body = _profile(client, "alice")
    assert body["recordings_per_month"] == 100
    assert body["recording_max_sec"] == 600
    assert body["voice_session_max_sec"] == 3600


def test_a_restored_account_does_not_get_a_second_quota(client, monkeypatch):
    """Signing back in merges the old account onto the caller's uid. Summing the
    two meters is the only direction that neither refunds nor double-charges."""
    monkeypatch.setattr(get_settings(), "recordings_per_month_free", 3)
    _record(client, "old-account", 5.0)
    _record(client, "new-session", 5.0)

    repo = get_repository()
    repo.merge_user("old-account", "new-session")

    assert repo.get_user_stats("new-session").voice_recordings_this_month == 2
