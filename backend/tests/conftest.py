from __future__ import annotations

import os

import pytest

# Force mock mode for the whole suite before app modules read settings.
os.environ.setdefault("VOICEIQ_MOCK", "1")
os.environ.pop("VOICEIQ_GCP_PROJECT", None)

# Pin the config profile. A developer with VOICEIQ_ENV=production exported in
# their shell would otherwise run the suite against config/production.env — real
# project, real Azure credential. Overwrite, don't default.
os.environ["VOICEIQ_ENV"] = "local"

# Settings also read the config profile, and production.env holds real Azure
# credentials. Blank them here — with `setdefault` these would leak through and a
# test run would email real people. Not negotiable: overwrite, don't default.
os.environ["VOICEIQ_ACS_CONNECTION_STRING"] = ""
os.environ["VOICEIQ_ACS_SENDER"] = ""
os.environ["VOICEIQ_ACS_FORCE_SEND"] = "0"

# One allowlisted admin for the whole suite. Deliberately a uid nothing else
# uses, so every other `auth(...)` caller is a genuine non-admin and the
# rejection tests are testing something real.
ADMIN_UID = "root-admin"
os.environ["VOICEIQ_ADMIN_UIDS"] = ADMIN_UID
os.environ["VOICEIQ_ADMIN_EMAILS"] = ""


@pytest.fixture(autouse=True)
def _reset_state():
    """Give every test a clean in-memory repository and transcript seed registry."""
    from app.core import activity
    from app.services import firestore, gemini, otp

    firestore.reset_repository()
    gemini._TRANSCRIPT_SEED.clear()
    otp.clear_mock_codes()
    # The activity cache is process-global and deliberately suppresses repeat
    # writes; leaving it populated would silently skip the write the next test
    # is asserting on.
    activity.reset_activity_cache()
    yield
    firestore.reset_repository()
    gemini._TRANSCRIPT_SEED.clear()
    otp.clear_mock_codes()
    activity.reset_activity_cache()


@pytest.fixture
def client():
    from fastapi.testclient import TestClient

    from app.main import create_app

    return TestClient(create_app())


def auth(uid: str) -> dict:
    """Auth headers for `uid` (mock mode treats the bearer token as the uid)."""
    return {"Authorization": f"Bearer {uid}"}


def admin_auth() -> dict:
    """Auth headers for the allowlisted admin."""
    return auth(ADMIN_UID)


@pytest.fixture
def make_recording(client):
    """Helper: create an indexed recording with a known transcript for `uid`."""

    def _make(uid: str, transcript: str, language: str = "en", event_date: str | None = None):
        up = client.post("/uploads", json={}, headers=auth(uid)).json()
        client.post(
            "/dev/seed-transcript",
            json={"audio_path": up["audio_path"], "transcript": transcript, "language": language},
            headers=auth(uid),
        )
        payload = {"audio_path": up["audio_path"], "duration_sec": 5.0}
        if event_date:
            payload["event_date"] = event_date
        return client.post("/recordings", json=payload, headers=auth(uid)).json()

    return _make


@pytest.fixture
def make_text_memory(client):
    """Helper: create an indexed *typed* memory for `uid`.

    No upload and no transcript seeding — the text is the transcript, which is
    the whole point of the path this exercises.
    """

    def _make(uid: str, text: str, event_date: str | None = None):
        payload: dict = {"text": text}
        if event_date:
            payload["event_date"] = event_date
        resp = client.post("/recordings/text", json=payload, headers=auth(uid))
        assert resp.status_code == 201, resp.text
        return resp.json()

    return _make


@pytest.fixture
def lift_recording_limits(monkeypatch):
    """Take the tier caps off recordings, for tests that are about something else.

    The admin counters, the duration histogram and the daily rollups all need
    recordings longer and more numerous than any tier allows — a 900-second one
    just to have something in the "600+" bucket. Making those tests buy premium
    and stay under it would be testing the entitlement twice and the statistic
    not at all, so they lift the caps instead. Tests *about* the caps set them.
    """
    from app.core.config import get_settings

    settings = get_settings()
    monkeypatch.setattr(settings, "recording_max_seconds_free", 10_000)
    monkeypatch.setattr(settings, "recording_max_seconds_premium", 10_000)
    monkeypatch.setattr(settings, "recordings_per_month_free", 10_000)
    monkeypatch.setattr(settings, "recordings_per_month_premium", 10_000)
    return settings


def set_tier(uid: str, tier: str) -> None:
    """Grant a tier the way the admin console does — server-side, never by the client."""
    from app.models.user import UserTier
    from app.services.firestore import get_repository

    repo = get_repository()
    repo.ensure_user_stats(uid)
    repo.set_tier(uid, UserTier(tier), None, "test-admin")
