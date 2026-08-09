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
