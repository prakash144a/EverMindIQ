from tests.conftest import auth, stale_auth


def test_health_is_public(client):
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json()["mock"] is True


def test_endpoints_require_auth(client):
    assert client.get("/recordings").status_code == 401
    assert client.post("/chat", json={"question": "hi"}).status_code == 401


def test_debug_uid_header_authenticates(client):
    r = client.get("/recordings", headers={"X-Debug-Uid": "alice", **auth("alice")})
    assert r.status_code == 200


def test_bearer_token_is_uid_in_mock(client):
    r = client.get("/recordings", headers=auth("bob"))
    assert r.status_code == 200
    assert r.json() == []


def test_a_token_without_a_live_session_is_refused(client):
    """The other half of authentication: an account is held by one device.

    A token alone used to be enough, which is what made a signed-out phone go on
    working and two phones share one account by accident.
    """
    r = client.get("/recordings", headers=stale_auth("carol"))
    assert r.status_code == 401
    assert r.json()["detail"]["code"] == "signed_out"
