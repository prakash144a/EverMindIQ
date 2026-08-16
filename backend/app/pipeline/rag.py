"""RAG query: embed question -> vector search -> grounded answer with citations."""

from __future__ import annotations

from app.core.config import get_settings
from app.models.chat import ChatRequest, ChatResponse, Citation
from app.services.embedding import get_embedder
from app.services.firestore import get_repository
from app.services.gemini import get_gemini


def answer_question(uid: str, req: ChatRequest) -> ChatResponse:
    settings = get_settings()
    repo = get_repository()

    top_k = req.top_k or settings.rag_top_k
    query_vec = get_embedder().embed(req.question)
    hits = repo.vector_search(
        uid, query_vec, top_k, date_from=req.date_from, date_to=req.date_to
    )

    # Keep only positive-similarity hits so we don't feed noise to the model.
    hits = [h for h in hits if h.score > 0]

    context_blocks = [
        f"[{h.recording.event_date.isoformat()}] {h.chunk.text}" for h in hits
    ]

    # No relevant memories: answer honestly instead of letting the model
    # hallucinate moments that were never recorded.
    if not context_blocks:
        return ChatResponse(
            answer="I couldn't find any memories related to that yet.",
            citations=[],
        )

    answer_language = req.answer_language or repo.get_settings_doc(uid).answer_language
    answer = get_gemini().answer(req.question, context_blocks, answer_language)

    # De-duplicate citations by recording, keeping the best-scoring snippet.
    seen: dict[str, Citation] = {}
    for h in hits:
        if h.recording.id not in seen:
            seen[h.recording.id] = Citation(
                recording_id=h.recording.id,
                event_date=h.recording.event_date,
                snippet=h.chunk.text[:200],
                score=round(h.score, 4),
            )
    return ChatResponse(answer=answer, citations=list(seen.values()))
