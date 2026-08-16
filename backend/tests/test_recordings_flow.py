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


def test_star_and_unstar_a_recording(make_recording, client):
    rec = make_recording("alice", "An ordinary Tuesday, nothing special.")
    assert rec["is_milestone"] is False

    starred = client.patch(
        f"/recordings/{rec['id']}", json={"is_milestone": True}, headers=auth("alice")
    )
    assert starred.status_code == 200
    assert starred.json()["is_milestone"] is True
    assert starred.json()["is_milestone_manual"] is True

    listed = client.get("/recordings", headers=auth("alice")).json()
    assert listed[0]["is_milestone"] is True

    unstarred = client.patch(
        f"/recordings/{rec['id']}", json={"is_milestone": False}, headers=auth("alice")
    )
    assert unstarred.json()["is_milestone"] is False
    assert unstarred.json()["is_milestone_manual"] is True


def test_patch_omitting_a_field_leaves_it_alone(make_recording, client):
    rec = make_recording("alice", "We got married today.")
    assert rec["is_milestone"] is True  # keyword heuristic flagged it

    patched = client.patch(f"/recordings/{rec['id']}", json={}, headers=auth("alice")).json()
    assert patched["is_milestone"] is True
    assert patched["is_milestone_manual"] is False


def test_patch_is_scoped_to_the_owner(make_recording, client):
    rec = make_recording("alice", "Alice's memory.")
    body = {"is_milestone": True}
    assert client.patch(f"/recordings/{rec['id']}", json=body, headers=auth("bob")).status_code == 404
    assert client.patch("/recordings/nope", json=body, headers=auth("alice")).status_code == 404
    assert client.get("/recordings", headers=auth("alice")).json()[0]["is_milestone"] is False


def test_reingest_does_not_clobber_a_hand_picked_star(make_recording, client):
    """Pub/Sub is at-least-once, so ingestion can re-run on a curated recording."""
    from app.pipeline.ingest import process_recording

    # The mock enricher would flag this transcript on its own.
    rec = make_recording("alice", "We got married today.")
    assert rec["is_milestone"] is True

    client.patch(f"/recordings/{rec['id']}", json={"is_milestone": False}, headers=auth("alice"))
    process_recording("alice", rec["id"])

    after = client.get("/recordings", headers=auth("alice")).json()[0]
    assert after["is_milestone"] is False, "re-ingestion overwrote the user's choice"


def test_delete_recording(make_recording, client):
    rec = make_recording("alice", "Delete me.")
    assert client.delete(f"/recordings/{rec['id']}", headers=auth("alice")).status_code == 204
    assert client.get("/recordings", headers=auth("alice")).json() == []
    assert client.get(f"/recordings/{rec['id']}", headers=auth("alice")).status_code == 404
