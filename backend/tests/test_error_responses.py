"""An unhandled error must still be readable by a browser.

Starlette's error middleware sits outside CORSMiddleware, so by default a crash
returns a bare 500 with no `Access-Control-Allow-Origin` header. A browser
cannot read that response and reports it as "Failed to fetch" — which is what
the admin console showed when a Firestore index was missing, telling the
operator nothing and sending the diagnosis down the wrong path entirely.
"""

import pytest
from fastapi.testclient import TestClient

from app.main import create_app
from app.services.firestore import get_repository
from tests.conftest import admin_auth

ORIGIN = "https://memoriesiq-admin.web.app"


@pytest.fixture
def exploding(monkeypatch):
    """An admin route whose repository call raises, as a missing index would."""

    def boom(*_args, **_kwargs):
        raise RuntimeError("the query requires an index")

    monkeypatch.setattr(get_repository(), "global_summary", boom)
    return TestClient(create_app(), raise_server_exceptions=False)


def test_a_crash_returns_json_not_an_empty_response(exploding):
    r = exploding.get("/admin/overview", headers=admin_auth())

    assert r.status_code == 500
    assert r.json()["detail"].startswith("Internal server error")


def test_a_crash_still_carries_cors_headers(exploding):
    """The regression that matters: without this the browser sees only
    "Failed to fetch" and the real 500 is invisible in the console."""
    r = exploding.get(
        "/admin/overview", headers={**admin_auth(), "Origin": ORIGIN}
    )

    assert r.status_code == 500
    assert r.headers.get("access-control-allow-origin") is not None


def test_normal_responses_are_unaffected(client):
    r = client.get("/health", headers={"Origin": ORIGIN})
    assert r.status_code == 200
    assert r.json()["status"] == "ok"


def test_binary_responses_pass_through_the_middleware_intact(client):
    """The middleware wraps every response, including raw audio bytes — so a
    non-JSON body must come back byte-for-byte."""
    from tests.conftest import auth

    up = client.post("/uploads", json={}, headers=auth("alice")).json()
    audio = b"\x00\x01binary-audio-payload\xff"
    client.put(up["upload_url"], content=audio, headers=up["headers"])
    rec = client.post(
        "/recordings",
        json={"audio_path": up["audio_path"], "duration_sec": 3.0},
        headers=auth("alice"),
    ).json()

    r = client.get(f"/recordings/{rec['id']}/audio", headers=auth("alice"))

    assert r.status_code == 200
    assert r.content == audio
