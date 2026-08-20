"""The audio half of `/live`: handshake, PCM framing, transcripts, citations.

Mock mode cannot recognize speech, so these drive a turn with a `text_turn`
frame rather than a microphone. What they prove is the transport — that a
session opens, that binary frames are treated as audio in both directions, that
a turn produces the transcript/citation/turn_complete frames the client's state
machine waits on, and that the text protocol still shares the socket.
"""

from __future__ import annotations

import contextlib
import struct

from app.core.config import get_settings
from app.services.live import OUTPUT_SAMPLE_RATE
from tests.conftest import set_tier


def _collect_turn(ws) -> tuple[list[dict], bytes]:
    """Read frames until the turn ends, splitting control JSON from audio."""
    control: list[dict] = []
    audio = bytearray()
    while True:
        frame = ws.receive()
        if "bytes" in frame and frame["bytes"] is not None:
            audio += frame["bytes"]
            continue
        import json

        msg = json.loads(frame["text"])
        control.append(msg)
        if msg.get("type") == "turn_complete" or "error" in msg:
            return control, bytes(audio)


def test_handshake_reports_no_audio_in_mock(client):
    """Mock mode must say so, not pretend: the client picks its path from this."""
    with client.websocket_connect("/live?token=alice") as ws:
        ws.send_json({"type": "audio_start"})
        ready = ws.receive_json()
    assert ready["type"] == "ready"
    assert ready["audio"] is False
    assert ready["reason"] == "mock"


def test_turn_returns_transcripts_citations_and_audio(make_recording, client):
    make_recording("alice", "We adopted a golden retriever puppy named Max.")

    with client.websocket_connect("/live?token=alice") as ws:
        ws.send_json({"type": "audio_start"})
        assert ws.receive_json()["type"] == "ready"
        ws.send_json({"type": "text_turn", "text": "What did we name the puppy?"})
        control, audio = _collect_turn(ws)

    kinds = [c["type"] for c in control]
    assert kinds[0] == "input_transcript"
    assert kinds[-1] == "turn_complete"
    assert "output_transcript" in kinds

    spoken = next(c["text"] for c in control if c["type"] == "output_transcript")
    assert "max" in spoken.lower() or "retriever" in spoken.lower()

    cited = next(c for c in control if c["type"] == "citations")
    assert cited["citations"], "a grounded answer must report what it drew on"

    # PCM16 mono: an even byte count, and long enough to be worth playing.
    assert len(audio) % 2 == 0
    assert len(audio) > OUTPUT_SAMPLE_RATE  # > 0.5s of 16-bit samples
    assert all(abs(s) <= 32767 for s in struct.unpack(f"<{len(audio) // 2}h", audio))


@contextlib.contextmanager
def _spy_sessions():
    """Hand back the list of sessions opened inside the block.

    The router imported `open_live_session` by name, so the router's reference has
    to be replaced too — patching only the module would spy on nothing.
    """
    from app.api.routers import live as live_router
    from app.services import live as live_module

    opened: list = []
    original = live_module.open_live_session

    def _spy(uid, journal_id=None):
        session = original(uid, journal_id)
        opened.append(session)
        return session

    live_module.open_live_session = _spy
    live_router.open_live_session = _spy
    try:
        yield opened
    finally:
        live_module.open_live_session = original
        live_router.open_live_session = original


def test_microphone_audio_is_consumed(client):
    """Binary frames must reach the session rather than being answered or dropped."""
    with _spy_sessions() as opened:
        with client.websocket_connect("/live?token=alice") as ws:
            ws.send_json({"type": "audio_start"})
            ws.receive_json()
            ws.send_bytes(b"\x00\x01" * 800)  # 1600 bytes of PCM16
            ws.send_json({"type": "text_turn", "text": "hello"})
            _collect_turn(ws)

    assert opened and opened[0].audio_bytes_in == 1600


def test_audio_before_session_is_ignored_not_fatal(client):
    """The client's first mic frames can outrun its own audio_start."""
    with client.websocket_connect("/live?token=alice") as ws:
        ws.send_bytes(b"\x00" * 64)
        ws.send_json({"question": "anything at all?"})
        resp = ws.receive_json()
    assert "answer" in resp


def test_text_turn_without_session_is_rejected(client):
    with client.websocket_connect("/live?token=alice") as ws:
        ws.send_json({"type": "text_turn", "text": "hello"})
        assert ws.receive_json()["type"] == "error"


def test_empty_turn_is_rejected(client):
    with client.websocket_connect("/live?token=alice") as ws:
        ws.send_json({"type": "audio_start"})
        ws.receive_json()
        ws.send_json({"type": "text_turn", "text": "   "})
        assert ws.receive_json()["type"] == "error"


def test_text_protocol_still_works_after_audio_ends(make_recording, client):
    """One socket, two protocols: ending a call must not end the chat."""
    make_recording("alice", "We adopted a golden retriever puppy named Max.")

    with client.websocket_connect("/live?token=alice") as ws:
        ws.send_json({"type": "audio_start"})
        ws.receive_json()
        ws.send_json({"type": "audio_end"})
        ws.send_json({"question": "What did we name the puppy?"})
        resp = ws.receive_json()
    assert resp["citations"]


def test_session_is_scoped_to_a_journal(client, make_text_memory):
    """A call opened from a journal answers from that journal only."""
    from tests.conftest import auth

    travel = client.post("/journals", json={"name": "Travel"}, headers=auth("alice")).json()
    make_text_memory("alice", "Ordinary Tuesday, nothing much happened.")
    client.post(
        "/recordings/text",
        json={"text": "We hiked the Kalsubai ridge at sunrise.", "journal_id": travel["id"]},
        headers=auth("alice"),
    )

    with client.websocket_connect("/live?token=alice") as ws:
        ws.send_json({"type": "audio_start", "journal_id": travel["id"]})
        ws.receive_json()
        ws.send_json({"type": "text_turn", "text": "What did I do at sunrise?"})
        control, _ = _collect_turn(ws)

    cited = next(c for c in control if c["type"] == "citations")
    assert cited["citations"]
    assert all("Tuesday" not in c["snippet"] for c in cited["citations"])


# -- how long a call may last -------------------------------------------


def test_the_handshake_states_the_time_limit(client):
    """The app counts the call down on screen, so it has to be told the budget at
    the start rather than discovering it when the socket goes quiet."""
    with client.websocket_connect("/live?token=alice") as ws:
        ws.send_json({"type": "audio_start"})
        assert ws.receive_json()["limit_sec"] == 600


def test_premium_is_told_a_longer_one(client):
    set_tier("alice", "premium")
    with client.websocket_connect("/live?token=alice") as ws:
        ws.send_json({"type": "audio_start"})
        assert ws.receive_json()["limit_sec"] == 3600


def test_the_call_is_ended_when_the_time_runs_out(client, monkeypatch):
    """`limit_reached` is its own frame, not an `error`: running out of the time
    you were told you had is the plan working, and the app says so in those words.

    Enforced by the session rather than the router because what it protects is an
    open Gemini Live socket, which bills for as long as it is held.
    """
    monkeypatch.setattr(get_settings(), "voice_session_max_seconds_free", 1)

    with client.websocket_connect("/live?token=alice") as ws:
        ws.send_json({"type": "audio_start"})
        assert ws.receive_json()["limit_sec"] == 1
        ended = ws.receive_json()

    assert ended["type"] == "limit_reached"
    assert ended["limit_sec"] == 1


def test_ending_a_call_early_cancels_the_hang_up(client, monkeypatch):
    """A timer that outlives its session is a task left running per call, holding
    the session it was meant to close. Hanging up has to take the clock with it."""
    monkeypatch.setattr(get_settings(), "voice_session_max_seconds_free", 60)

    with _spy_sessions() as opened:
        with client.websocket_connect("/live?token=alice") as ws:
            ws.send_json({"type": "audio_start"})
            ws.receive_json()
            assert opened[0]._deadline is not None, "the clock should be running"
            ws.send_json({"type": "audio_end"})
            # The typed protocol shares this socket, so a round trip on it is also
            # proof that ending the call did not end the connection.
            ws.send_json({"question": "still there?"})
            assert "answer" in ws.receive_json()

    assert opened[0]._deadline is None
