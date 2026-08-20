"""Talk-to-AI real-time channel.

Carries two protocols on one socket, because they are two halves of the same
conversation and the client switches between them without reconnecting:

**Text** (unchanged) — the client sends ``{"question": ...}`` and gets one
``ChatResponse`` back. This is the Recall screen's chat.

**Audio** — the client sends ``{"type": "audio_start"}``, then streams raw
microphone PCM as binary frames. It gets binary PCM back to play, plus JSON
frames for transcripts, citations, interruptions and turn boundaries. The bridge
to Gemini Live lives in ``services.live``; this router is only the wire.

Binary frames are audio and JSON frames are control — that is the whole framing
rule, in both directions.
"""

from __future__ import annotations

import asyncio
import contextlib
import json

from fastapi import APIRouter, Query, WebSocket, WebSocketDisconnect

from app.core.config import get_settings
from app.core.security import CurrentUser
from app.models.chat import ChatRequest
from app.pipeline.rag import answer_question
from app.services.live import LiveSession, open_live_session

router = APIRouter(tags=["live"])


async def _resolve_ws_user(websocket: WebSocket, token: str | None) -> CurrentUser | None:
    settings = get_settings()
    if settings.effective_mock:
        uid = token or websocket.query_params.get("uid")
        if not uid:
            return None
        return CurrentUser(uid=uid, email=f"{uid}@mock.local")
    # Real mode: verify the Firebase token passed as a query param on connect.
    from app.core.security import _verify_firebase_token  # pragma: no cover

    if not token:  # pragma: no cover
        return None
    try:  # pragma: no cover
        return _verify_firebase_token(token, settings)
    except Exception:  # pragma: no cover
        return None


class _Wire:
    """Serializes sends, since the audio forwarder and the request loop share one socket."""

    def __init__(self, websocket: WebSocket) -> None:
        self._ws = websocket
        self._lock = asyncio.Lock()

    async def json(self, payload: dict) -> None:
        async with self._lock:
            await self._ws.send_json(payload)

    async def audio(self, pcm: bytes) -> None:
        async with self._lock:
            await self._ws.send_bytes(pcm)


async def _forward(session: LiveSession, wire: _Wire) -> None:
    """Drain the bridge onto the socket until the session ends."""
    async for event in session.events():
        if event.kind == "audio":
            await wire.audio(event.audio)
        else:
            await wire.json({"type": event.kind, **event.payload})


@router.websocket("/live")
async def live(websocket: WebSocket, token: str | None = Query(default=None)) -> None:
    user = await _resolve_ws_user(websocket, token)
    if user is None:
        await websocket.close(code=4401)  # unauthorized
        return
    await websocket.accept()

    wire = _Wire(websocket)
    session: LiveSession | None = None
    pump: asyncio.Task | None = None

    async def stop_audio() -> None:
        nonlocal session, pump
        if session is not None:
            await session.aclose()
        if pump is not None:
            # The forwarder may be mid-send on a socket the client just closed.
            # That is the ordinary way a call ends, not a failure to report.
            with contextlib.suppress(Exception):
                await pump
        session, pump = None, None

    try:
        while True:
            frame = await websocket.receive()
            if frame["type"] == "websocket.disconnect":
                return

            # Binary is always microphone audio for an open session. Arriving
            # with no session is not an error worth closing over — it is the
            # normal race between the client's first frames and its own
            # audio_start — so it is dropped quietly.
            pcm = frame.get("bytes")
            if pcm is not None:
                if session is not None:
                    await session.send_audio(pcm)
                continue

            try:
                msg = json.loads(frame.get("text") or "{}")
            except json.JSONDecodeError:
                await wire.json({"error": "expected JSON"})
                continue
            if not isinstance(msg, dict):
                await wire.json({"error": "expected a JSON object"})
                continue

            kind = msg.get("type")

            if kind == "audio_start":
                if session is not None:
                    await stop_audio()
                session = open_live_session(user.uid, msg.get("journal_id"))
                await session.start()
                pump = asyncio.create_task(_forward(session, wire))
                continue

            if kind == "audio_end":
                await stop_audio()
                continue

            if kind == "text_turn":
                # A typed turn inside a voice conversation: same session, same
                # voice answering, so switching to the keyboard mid-conversation
                # does not restart it.
                if session is None:
                    await wire.json(
                        {"type": "error", "message": "no live session; send audio_start first"}
                    )
                    continue
                await session.send_text(str(msg.get("text", "")))
                continue

            question = str(msg.get("question", "")).strip()
            if not question:
                await wire.json({"error": "expected {'question': ...}"})
                continue
            resp = answer_question(
                user.uid,
                ChatRequest(
                    question=question,
                    answer_language=msg.get("answer_language"),
                    journal_id=msg.get("journal_id"),
                ),
            )
            await wire.json(resp.model_dump(mode="json"))
    except WebSocketDisconnect:
        return
    finally:
        await stop_audio()
