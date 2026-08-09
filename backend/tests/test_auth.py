from tests.conftest import auth


def test_healthz_is_public(client):
    r = client.get("/healthz")
    assert r.status_code == 200
    assert r.json()["mock"] is True


def test_endpoints_require_auth(client):
    assert client.get("/recordings").status_code == 401
    assert client.post("/chat", json={"question": "hi"}).status_code == 401


def test_debug_uid_header_authenticates(client):
    r = client.get("/recordings", headers={"X-Debug-Uid": "alice"})
    assert r.status_code == 200


def test_bearer_token_is_uid_in_mock(client):
    r = client.get("/recordings", headers=auth("bob"))
    assert r.status_code == 200
    assert r.json() == []
