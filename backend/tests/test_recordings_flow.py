from tests.conftest import auth


def test_upload_returns_signed_url_scoped_to_user(client):
    r = client.post("/uploads", json={}, headers=auth("alice"))
    assert r.status_code == 200
    body = r.json()
    assert body["audio_path"].startswith("gs://")
    assert "users/alice/audio/" in body["audio_path"]
    assert body["method"] == "PUT"


def test_record_gets_transcribed_and_indexed(make_recording, client):
    rec = make_recording("alice", "Today I hiked Table Mountain with Sarah. It was beautiful.")
    assert rec["status"] == "indexed"
    assert "Table Mountain" in rec["transcript"]
    assert rec["title"]
    assert rec["summary"]
    # Entity extraction picked up capitalized names/places.
    assert "Sarah" in rec["people"] or "Table" in rec["people"]


def test_backdated_event_date_is_respected(make_recording):
    rec = make_recording("alice", "A memory from long ago.", event_date="2020-01-15")
    assert rec["event_date"] == "2020-01-15"


def test_list_and_get_recording(make_recording, client):
    rec = make_recording("alice", "Sample memory about coffee.")
    listed = client.get("/recordings", headers=auth("alice")).json()
    assert len(listed) == 1

    got = client.get(f"/recordings/{rec['id']}", headers=auth("alice"))
    assert got.status_code == 200
    assert got.json()["audio_url"].startswith("https://")


def test_delete_recording(make_recording, client):
    rec = make_recording("alice", "Delete me.")
    assert client.delete(f"/recordings/{rec['id']}", headers=auth("alice")).status_code == 204
    assert client.get("/recordings", headers=auth("alice")).json() == []
    assert client.get(f"/recordings/{rec['id']}", headers=auth("alice")).status_code == 404
