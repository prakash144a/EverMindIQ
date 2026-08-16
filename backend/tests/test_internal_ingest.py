import base64
import json

from tests.conftest import auth


def _envelope(uid: str, recording_id: str) -> dict:
    data = base64.b64encode(
        json.dumps({"uid": uid, "recording_id": recording_id}).encode()
    ).decode()
    return {"message": {"data": data, "messageId": "1"}, "subscription": "x"}


def test_internal_ingest_processes_a_pubsub_push(make_recording, client):
    rec = make_recording("alice", "A memory to (re)index via the worker path.")
    r = client.post("/internal/ingest", json=_envelope("alice", rec["id"]))
    assert r.status_code == 204

    got = client.get(f"/recordings/{rec['id']}", headers=auth("alice")).json()
    assert got["recording"]["status"] == "indexed"


def test_internal_ingest_rejects_bad_envelope(client):
    assert client.post("/internal/ingest", json={}).status_code == 400


def test_a_message_for_a_deleted_recording_is_acked_not_retried(client, make_recording):
    """Pub/Sub redelivers on any non-2xx, so a permanently-gone recording must ack.

    Seen in production: messages that outlived their data retried until they
    expired, filling the logs with tracebacks and burning invocations.
    """
    import base64
    import json

    payload = base64.b64encode(
        json.dumps({"uid": "alice", "recording_id": "never-existed"}).encode()
    ).decode()

    r = client.post("/internal/ingest", json={"message": {"data": payload}})
    assert r.status_code == 204, "a permanent failure must be acked, not retried"
