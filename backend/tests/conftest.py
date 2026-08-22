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
    """Auth headers for `uid`: a bearer token, and the session that device holds.

    Mock mode treats the bearer token as the uid. The session id is the other
    half — an account may be held by one device at a time, so a token alone is
    refused. Opening one here on demand keeps every test that is *about*
    something else talking to the API the way a signed-in app does; the tests
    about signing in and out drive the real endpoints instead (see
    `test_auth_sessions.py`).
    """
    from app.models.user import DeviceSession
    from app.services.firestore import get_repository

    repo = get_repository()
    held = repo.get_session(uid)
    if held is None:
        held = repo.save_session(
            uid,
            DeviceSession(
                session_id=f"ses-{uid}", install_id=f"install-{uid}", platform="android"
            ),
        )
    return {"Authorization": f"Bearer {uid}", "X-Session-Id": held.session_id}


def sign_in(client, email: str, install_id: str = "phone-a", name: str = "") -> dict:
    """Log in the way the app does. Returns `{uid, token, session_id, profile}`.

    For tests that need a *real* account — one the email index knows about, with
    a server-issued id — rather than the ad-hoc uid `auth()` conjures.
    """
    from app.services.otp import peek_mock_code

    device = {"X-Install-Id": install_id, "X-Platform": "android", "X-App-Version": "1.0.0"}
    asked = client.post("/auth/otp/request", json={"email": email}, headers=device)
    assert asked.status_code == 204, asked.text
    verified = client.post(
        "/auth/otp/verify",
        json={"email": email, "code": peek_mock_code(email), "preferred_name": name},
        headers=device,
    )
    assert verified.status_code == 200, verified.text
    claimed = client.post(
        "/auth/session", json={"ticket": verified.json()["ticket"], "takeover": True}
    )
    assert claimed.status_code == 200, claimed.text
    return {**claimed.json(), "status": verified.json()["status"]}


def session_headers(body: dict) -> dict:
    """Headers for the device that `sign_in` just signed in."""
    return {"Authorization": f"Bearer {body['token']}", "X-Session-Id": body["session_id"]}


def stale_auth(uid: str, session_id: str = "ses-gone") -> dict:
    """Headers for a device whose session is no longer the live one."""
    return {"Authorization": f"Bearer {uid}", "X-Session-Id": session_id}


def ws_url(uid: str, path: str = "/live", **params: str) -> str:
    """A WebSocket URL carrying the same credentials `auth` produces."""
    session = auth(uid)["X-Session-Id"]
    extra = "".join(f"&{k}={v}" for k, v in params.items())
    return f"{path}?token={uid}&session={session}{extra}"


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
