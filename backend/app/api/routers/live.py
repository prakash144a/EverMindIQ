"""Talk-to-AI real-time channel.

Real mode: this endpoint is a thin proxy that bridges the client WebSocket to **Gemini Live**,
injecting the user's retrieved memory context per turn (keys stay server-side).

Mock mode: a text/JSON stand-in that runs the same RAG turn-by-turn, so the client's Talk screen and
the conversation loop are fully exercisable offline. Client sends {"question": "..."} and receives
{"answer": "...", "citations": [...]}.
"""

from __future__ import annotations

from fastapi import APIRouter, Query, WebSocket, WebSocketDisconnect

from app.core.config import get_settings
from app.core.security import CurrentUser
from app.models.chat import ChatRequest
from app.pipeline.rag import answer_question

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


@router.websocket("/live")
async def live(websocket: WebSocket, token: str | None = Query(default=None)) -> None:
    user = await _resolve_ws_user(websocket, token)
    if user is None:
        await websocket.close(code=4401)  # unauthorized
        return
    await websocket.accept()
    try:
        while True:
            msg = await websocket.receive_json()
            question = (msg or {}).get("question", "").strip()
            if not question:
                await websocket.send_json({"error": "expected {'question': ...}"})
                continue
            resp = answer_question(
                user.uid,
                ChatRequest(
                    question=question,
                    answer_language=(msg or {}).get("answer_language"),
                    journal_id=(msg or {}).get("journal_id"),
                ),
            )
            await websocket.send_json(resp.model_dump(mode="json"))
    except WebSocketDisconnect:
        return
