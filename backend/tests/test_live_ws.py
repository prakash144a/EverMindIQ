from tests.conftest import ws_url


def test_live_ws_requires_token(client):
    import pytest
    from starlette.websockets import WebSocketDisconnect

    with pytest.raises(WebSocketDisconnect):
        with client.websocket_connect("/live"):
            pass


def test_live_ws_answers_from_memories(make_recording, client):
    make_recording("alice", "We adopted a golden retriever puppy named Max.")

    with client.websocket_connect(ws_url("alice")) as ws:
        ws.send_json({"question": "What did we name the puppy?"})
        resp = ws.receive_json()
    assert resp["citations"]
    assert "max" in resp["answer"].lower() or "retriever" in resp["answer"].lower()


def test_live_ws_rejects_empty_question(client):
    with client.websocket_connect(ws_url("bob")) as ws:
        ws.send_json({"question": "   "})
        resp = ws.receive_json()
    assert "error" in resp
