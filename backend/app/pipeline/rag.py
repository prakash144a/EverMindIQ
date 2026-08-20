"""RAG query: embed question -> vector search -> grounded answer with citations."""

from __future__ import annotations

from dataclasses import dataclass, field

from app.core.config import get_settings
from app.models.chat import ChatRequest, ChatResponse, Citation
from app.models.journal import Journal
from app.pipeline.journal_scope import detect_journal
from app.services.embedding import get_embedder
from app.services.firestore import get_repository
from app.services.gemini import get_gemini


def _resolve_scope(repo, uid: str, req: ChatRequest) -> Journal | None:
    """The journal to answer from, honouring the request's three states.

    An explicit `""` means the user has already said "everything", so the
    question's own wording must not narrow it behind their back — that is the
    whole purpose of the "Ask all memories" action.
    """
    if req.journal_id == "":
        return None
    if req.journal_id:
        return repo.get_journal(uid, req.journal_id)
    return detect_journal(req.question, repo.list_journals(uid))


@dataclass
class Retrieval:
    """What the search found, before any model has spoken about it.

    Split out from `answer_question` because Talk-to-AI voice needs the same
    memories without the same answer: in a live session Gemini composes the
    reply itself, from audio, and calling `answer_question` there would mean a
    second model writing a second answer that the first one then reads out.
    """

    context_blocks: list[str] = field(default_factory=list)
    citations: list[Citation] = field(default_factory=list)
    journal: Journal | None = None

    @property
    def scope(self) -> dict[str, str]:
        """The journal fields every response echoes back, empty when unscoped."""
        if not self.journal:
            return {}
        return {"journal_id": self.journal.id, "journal_name": self.journal.name}


def retrieve(uid: str, req: ChatRequest) -> Retrieval:
    """Find the memories relevant to `req`, scoped as the request asks."""
    settings = get_settings()
    repo = get_repository()

    journal = _resolve_scope(repo, uid, req)

    top_k = req.top_k or settings.rag_top_k
    query_vec = get_embedder().embed(req.question)
    hits = repo.vector_search(
        uid,
        query_vec,
        top_k,
        date_from=req.date_from,
        date_to=req.date_to,
        journal_id=journal.id if journal else None,
    )

    # Keep only positive-similarity hits so we don't feed noise to the model.
    hits = [h for h in hits if h.score > 0]

    context_blocks = [
        f"[{h.recording.event_date.isoformat()}] {h.chunk.text}" for h in hits
    ]

    # De-duplicate citations by recording, keeping the best-scoring snippet.
    seen: dict[str, Citation] = {}
    for h in hits:
        if h.recording.id not in seen:
            seen[h.recording.id] = Citation(
                recording_id=h.recording.id,
                event_date=h.recording.event_date,
                snippet=h.chunk.text[:200],
                score=round(h.score, 4),
                source=h.recording.source,
            )
    return Retrieval(context_blocks, list(seen.values()), journal)


def answer_question(uid: str, req: ChatRequest) -> ChatResponse:
    repo = get_repository()
    found = retrieve(uid, req)
    journal = found.journal

    # No relevant memories: answer honestly instead of letting the model
    # hallucinate moments that were never recorded. When the search was scoped,
    # say so — the memory may well exist, just filed somewhere else, and the
    # generic line would be a small lie.
    if not found.context_blocks:
        return ChatResponse(
            answer=(
                f"I couldn't find anything about that in your {journal.name} journal."
                if journal
                else "I couldn't find any memories related to that yet."
            ),
            citations=[],
            **found.scope,
        )

    answer_language = req.answer_language or repo.get_settings_doc(uid).answer_language
    # Name the frame the model is answering in, so a scoped answer reads as one.
    question = (
        f"(About my {journal.name} journal) {req.question}" if journal else req.question
    )
    answer = get_gemini().answer(question, found.context_blocks, answer_language)

    return ChatResponse(answer=answer, citations=found.citations, **found.scope)
