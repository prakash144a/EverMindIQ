from tests.conftest import auth


def test_settings_roundtrip(client):
    default = client.get("/settings", headers=auth("alice")).json()
    assert default["answer_language"] == "auto"

    default["answer_language"] = "en"
    default["on_this_day_enabled"] = False
    saved = client.put("/settings", json=default, headers=auth("alice")).json()
    assert saved["answer_language"] == "en"
    assert saved["on_this_day_enabled"] is False

    again = client.get("/settings", headers=auth("alice")).json()
    assert again["answer_language"] == "en"


def test_account_deletion_purges_everything(make_recording, client):
    make_recording("alice", "Something to remember.")
    assert client.get("/recordings", headers=auth("alice")).json()

    assert client.delete("/account", headers=auth("alice")).status_code == 204
    assert client.get("/recordings", headers=auth("alice")).json() == []
    # RAG finds nothing after purge.
    r = client.post("/chat", json={"question": "anything?"}, headers=auth("alice"))
    assert r.json()["citations"] == []
