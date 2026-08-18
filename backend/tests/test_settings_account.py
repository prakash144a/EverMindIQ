from tests.conftest import auth


def test_settings_roundtrip(client):
    default = client.get("/settings", headers=auth("alice")).json()
    assert default["answer_language"] == "auto"
    assert default["theme_mode"] == "system"

    default["answer_language"] = "en"
    default["on_this_day_enabled"] = False
    default["theme_mode"] = "dark"
    saved = client.put("/settings", json=default, headers=auth("alice")).json()
    assert saved["answer_language"] == "en"
    assert saved["on_this_day_enabled"] is False
    assert saved["theme_mode"] == "dark"

    again = client.get("/settings", headers=auth("alice")).json()
    assert again["answer_language"] == "en"
    assert again["theme_mode"] == "dark"


def test_settings_rejects_unknown_theme_mode(client):
    body = client.get("/settings", headers=auth("alice")).json()
    body["theme_mode"] = "sepia"
    assert client.put("/settings", json=body, headers=auth("alice")).status_code == 422


def test_settings_put_keeps_fields_the_client_omitted(client):
    """An old build saving settings must not wipe fields it has never heard of."""
    body = client.get("/settings", headers=auth("alice")).json()
    body["theme_mode"] = "dark"
    client.put("/settings", json=body, headers=auth("alice"))

    legacy = {k: v for k, v in body.items() if k != "theme_mode"}
    legacy["answer_language"] = "en"
    client.put("/settings", json=legacy, headers=auth("alice"))

    again = client.get("/settings", headers=auth("alice")).json()
    assert again["theme_mode"] == "dark"  # survived the old-client round trip
    assert again["answer_language"] == "en"


def test_account_deletion_purges_everything(make_recording, client):
    make_recording("alice", "Something to remember.")
    assert client.get("/recordings", headers=auth("alice")).json()

    assert client.delete("/account", headers=auth("alice")).status_code == 204
    assert client.get("/recordings", headers=auth("alice")).json() == []
    # RAG finds nothing after purge.
    r = client.post("/chat", json={"question": "anything?"}, headers=auth("alice"))
    assert r.json()["citations"] == []
