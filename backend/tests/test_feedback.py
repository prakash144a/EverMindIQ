from tests.conftest import auth


def test_submit_and_read_back_own_feedback(client):
    r = client.post(
        "/feedback",
        json={
            "kind": "problem",
            "message": "Pull to refresh threw a cast error.",
            "diagnostics": "type 'List<dynamic>' is not a subtype of type 'String?'",
            "app_version": "1.0.0+3",
            "platform": "android",
        },
        headers=auth("alice"),
    )
    assert r.status_code == 201
    body = r.json()
    assert body["uid"] == "alice"
    assert body["kind"] == "problem"
    assert "cast error" in body["message"]
    assert body["app_version"] == "1.0.0+3"

    listed = client.get("/feedback", headers=auth("alice")).json()
    assert len(listed) == 1
    assert listed[0]["id"] == body["id"]


def test_feedback_requires_auth(client):
    assert client.post("/feedback", json={"message": "hi"}).status_code in (401, 403)
    assert client.get("/feedback").status_code in (401, 403)


def test_feedback_is_private_to_its_author(client):
    client.post("/feedback", json={"message": "Alice's report"}, headers=auth("alice"))
    assert client.get("/feedback", headers=auth("bob")).json() == []


def test_diagnostics_are_optional(client):
    r = client.post("/feedback", json={"message": "Just an idea."}, headers=auth("alice"))
    assert r.status_code == 201
    # A report must never be blocked on having captured an error.
    assert r.json()["diagnostics"] == ""
    assert r.json()["kind"] == "problem"


def test_empty_message_is_rejected(client):
    assert client.post("/feedback", json={"message": ""}, headers=auth("alice")).status_code == 422


def test_oversized_diagnostics_are_rejected(client):
    r = client.post(
        "/feedback",
        json={"message": "big", "diagnostics": "x" * 20_001},
        headers=auth("alice"),
    )
    assert r.status_code == 422


def test_deleting_the_account_removes_feedback(client):
    client.post("/feedback", json={"message": "report"}, headers=auth("alice"))
    assert client.delete("/account", headers=auth("alice")).status_code == 204
    assert client.get("/feedback", headers=auth("alice")).json() == []
