from __future__ import annotations

from datetime import date

from pydantic import BaseModel, Field

from app.models.recording import RecordingSource


class ChatRequest(BaseModel):
    question: str
    # Optional date filter to scope retrieval (e.g. "trips this year").
    date_from: date | None = None
    date_to: date | None = None
    # "auto" matches the question language; or an ISO code like "en".
    answer_language: str | None = None
    top_k: int | None = None
    # Which journal to answer from. Three-state, and the distinction matters:
    #   None  -> no scope chosen; the question itself may name one
    #   ""    -> the user explicitly asked across everything; do not infer
    #   "abc" -> that journal, and only that journal
    journal_id: str | None = None


class Citation(BaseModel):
    recording_id: str
    event_date: date
    snippet: str
    score: float
    # So the client knows whether to offer playback. Without it a cited typed
    # memory renders a play button that can only fail.
    source: RecordingSource = RecordingSource.voice


class ChatResponse(BaseModel):
    answer: str
    citations: list[Citation] = Field(default_factory=list)
    # Which journal this answer came from, empty when it drew on everything.
    # Echoed back because the scope may have been inferred from the question,
    # and an answer narrowed without saying so is an answer that looks wrong.
    journal_id: str = ""
    journal_name: str = ""
