from tests.conftest import auth


def test_live_ws_requires_token(client):
    import pytest
    from starlette.websockets import WebSocketDisconnect

    with pytest.raises(WebSocketDisconnect):
        with client.websocket_connect("/live"):
            pass


def test_live_ws_answers_from_memories(make_recording, client):
    make_recording("alice", "We adopted a golden retriever puppy named Max.")

    with client.websocket_connect("/live?token=alice") as ws:
        ws.send_json({"question": "What did we name the puppy?"})
        resp = ws.receive_json()
    assert resp["citations"]
    assert "max" in resp["answer"].lower() or "retriever" in resp["answer"].lower()


def test_live_ws_rejects_empty_question(client):
    # No auth setup needed beyond the token; empty question yields an error frame.
    _ = auth  # keep import used
    with client.websocket_connect("/live?token=bob") as ws:
        ws.send_json({"question": "   "})
        resp = ws.receive_json()
    assert "error" in resp
