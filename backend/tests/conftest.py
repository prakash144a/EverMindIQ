from __future__ import annotations

import os

import pytest

# Force mock mode for the whole suite before app modules read settings.
os.environ.setdefault("VOICEIQ_MOCK", "1")
os.environ.pop("VOICEIQ_GCP_PROJECT", None)


@pytest.fixture(autouse=True)
def _reset_state():
    """Give every test a clean in-memory repository and transcript seed registry."""
    from app.services import firestore, gemini

    firestore.reset_repository()
    gemini._TRANSCRIPT_SEED.clear()
    yield
    firestore.reset_repository()
    gemini._TRANSCRIPT_SEED.clear()


@pytest.fixture
def client():
    from fastapi.testclient import TestClient

    from app.main import create_app

    return TestClient(create_app())


def auth(uid: str) -> dict:
    """Auth headers for `uid` (mock mode treats the bearer token as the uid)."""
    return {"Authorization": f"Bearer {uid}"}


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
