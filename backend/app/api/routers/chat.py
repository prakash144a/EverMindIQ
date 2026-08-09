from __future__ import annotations

from fastapi import APIRouter, Depends

from app.core.security import CurrentUser, get_current_user
from app.models.chat import ChatRequest, ChatResponse
from app.pipeline.rag import answer_question

router = APIRouter(prefix="/chat", tags=["chat"])


@router.post("", response_model=ChatResponse)
def ask(
    body: ChatRequest,
    user: CurrentUser = Depends(get_current_user),
) -> ChatResponse:
    """Ask anything about your past memories (text RAG). Voice uses the /live WebSocket."""
    return answer_question(user.uid, body)
