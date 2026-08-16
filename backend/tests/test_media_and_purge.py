"""Container/MIME handling and audio-blob lifecycle.

Both behaviors were found missing by the real-mode verification pass: uploads were
stored as `.m4a` whatever their actual container, and deleting a recording (or a
whole account) left the audio object behind in GCS forever.
"""

from app.core.media import content_type_for_path, ext_for_content_type
from app.services.storage import get_storage
from tests.conftest import auth


def _upload_and_create(client, uid: str, audio: bytes, content_type: str = "audio/m4a") -> dict:
    up = client.post("/uploads", json={"content_type": content_type}, headers=auth(uid)).json()
    assert client.put(up["upload_url"], content=audio, headers=up["headers"]).status_code == 200
    rec = client.post(
        "/recordings",
        json={"audio_path": up["audio_path"], "duration_sec": 5.0},
        headers=auth(uid),
    )
    assert rec.status_code == 201
    return {**rec.json(), "audio_path": up["audio_path"]}


# -- mapping ------------------------------------------------------------------


def test_ext_follows_the_uploaded_container():
    assert ext_for_content_type("audio/webm") == ".webm"
    assert ext_for_content_type("audio/wav") == ".wav"
    assert ext_for_content_type("audio/m4a") == ".m4a"
    # Parameters and casing are noise, not a different type.
    assert ext_for_content_type("AUDIO/WEBM; codecs=opus") == ".webm"
    # Unknown types fall back to the mobile default rather than losing the file.
    assert ext_for_content_type("application/octet-stream") == ".m4a"


def test_content_type_round_trips_through_the_object_name():
    for ct in ("audio/webm", "audio/wav", "audio/mpeg"):
        assert content_type_for_path(f"gs://b/o{ext_for_content_type(ct)}") == ct
    # "audio/m4a" is not an IANA type; it normalizes to the standard name.
    assert content_type_for_path("gs://b/o.m4a") == "audio/mp4"


def test_upload_path_uses_the_declared_container(client):
    up = client.post("/uploads", json={"content_type": "audio/webm"}, headers=auth("alice")).json()
    assert up["audio_path"].endswith(".webm")


def test_playback_serves_the_container_that_was_uploaded(client):
    rec = _upload_and_create(client, "alice", b"webm-bytes", content_type="audio/webm")
    r = client.get(f"/recordings/{rec['id']}/audio", headers=auth("alice"))
    assert r.status_code == 200
    assert r.headers["content-type"].startswith("audio/webm")


# -- blob lifecycle -----------------------------------------------------------


def test_deleting_a_recording_deletes_its_audio(client):
    rec = _upload_and_create(client, "alice", b"some-audio")
    storage = get_storage()
    assert storage.read_bytes(rec["audio_path"]) == b"some-audio"

    assert client.delete(f"/recordings/{rec['id']}", headers=auth("alice")).status_code == 204
    assert storage.read_bytes(rec["audio_path"]) == b""


def test_deleting_someone_elses_recording_leaves_their_audio_alone(client):
    rec = _upload_and_create(client, "alice", b"alice-audio")

    assert client.delete(f"/recordings/{rec['id']}", headers=auth("bob")).status_code == 404
    assert get_storage().read_bytes(rec["audio_path"]) == b"alice-audio"


def test_account_purge_removes_every_audio_object(client):
    first = _upload_and_create(client, "alice", b"one")
    second = _upload_and_create(client, "alice", b"two")
    survivor = _upload_and_create(client, "bob", b"bob-audio")

    assert client.delete("/account", headers=auth("alice")).status_code == 204

    storage = get_storage()
    assert storage.read_bytes(first["audio_path"]) == b""
    assert storage.read_bytes(second["audio_path"]) == b""
    # Another user's blobs share the bucket, so the prefix sweep must not overreach.
    assert storage.read_bytes(survivor["audio_path"]) == b"bob-audio"


def test_account_purge_sweeps_uploads_that_were_never_registered(client):
    """An upload URL issued to a client that then crashed leaves an orphan blob."""
    up = client.post("/uploads", json={}, headers=auth("alice")).json()
    client.put(up["upload_url"], content=b"orphan", headers=up["headers"])

    assert client.delete("/account", headers=auth("alice")).status_code == 204
    assert get_storage().read_bytes(up["audio_path"]) == b""
