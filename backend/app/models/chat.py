from __future__ import annotations

from datetime import date

from pydantic import BaseModel, Field


class ChatRequest(BaseModel):
    question: str
    # Optional date filter to scope retrieval (e.g. "trips this year").
    date_from: date | None = None
    date_to: date | None = None
    # "auto" matches the question language; or an ISO code like "en".
    answer_language: str | None = None
    top_k: int | None = None


class Citation(BaseModel):
    recording_id: str
    event_date: date
    snippet: str
    score: float


class ChatResponse(BaseModel):
    answer: str
    citations: list[Citation] = Field(default_factory=list)
