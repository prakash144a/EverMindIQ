from tests.conftest import auth


def _upload_and_create(client, uid: str, audio: bytes, content_type: str = "audio/m4a") -> dict:
    """Full record flow: signed URL -> PUT bytes to mock storage -> register recording."""
    up = client.post("/uploads", json={"content_type": content_type}, headers=auth(uid)).json()
    put = client.put(up["upload_url"], content=audio, headers=up["headers"])
    assert put.status_code == 200
    rec = client.post(
        "/recordings",
        json={"audio_path": up["audio_path"], "duration_sec": 5.0},
        headers=auth(uid),
    )
    assert rec.status_code == 201
    return rec.json()


def test_audio_endpoint_returns_uploaded_bytes(client):
    audio = b"fake-m4a-bytes-\x00\x01\x02"
    rec = _upload_and_create(client, "alice", audio)

    r = client.get(f"/recordings/{rec['id']}/audio", headers=auth("alice"))
    assert r.status_code == 200
    assert r.content == audio
    assert r.headers["content-type"].startswith("audio/")


def test_audio_endpoint_is_isolated_per_user(client):
    rec = _upload_and_create(client, "alice", b"alice-audio")

    # Bob must not be able to fetch Alice's audio.
    r = client.get(f"/recordings/{rec['id']}/audio", headers=auth("bob"))
    assert r.status_code == 404


def test_audio_endpoint_404_for_unknown_recording(client):
    r = client.get("/recordings/does-not-exist/audio", headers=auth("alice"))
    assert r.status_code == 404


def test_a_web_recording_is_served_back_as_the_format_it_was_recorded_in(client):
    """The phone has to be able to play what the browser recorded.

    A browser records webm and a phone records m4a; both land in one account and
    either can be opened from either place. The player is handed whatever this
    says, so serving a webm file as `audio/mp4` is a memory that will not play.
    """
    rec = _upload_and_create(client, "alice", b"fake-webm-bytes", content_type="audio/webm")

    r = client.get(f"/recordings/{rec['id']}/audio", headers=auth("alice"))
    assert r.status_code == 200
    assert r.headers["content-type"].startswith("audio/webm")


def test_a_phone_recording_is_served_back_as_mp4(client):
    rec = _upload_and_create(client, "alice", b"fake-m4a-bytes", content_type="audio/m4a")

    r = client.get(f"/recordings/{rec['id']}/audio", headers=auth("alice"))
    assert r.headers["content-type"].startswith("audio/mp4")
