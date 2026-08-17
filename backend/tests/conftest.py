from __future__ import annotations

import os

import pytest

# Force mock mode for the whole suite before app modules read settings.
os.environ.setdefault("VOICEIQ_MOCK", "1")
os.environ.pop("VOICEIQ_GCP_PROJECT", None)

# Settings also read backend/.env, which on a developer machine holds real Azure
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
