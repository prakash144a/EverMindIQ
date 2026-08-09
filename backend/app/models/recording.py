from __future__ import annotations

from datetime import date, datetime, timezone
from enum import Enum

from pydantic import BaseModel, Field


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


class RecordingStatus(str, Enum):
    uploaded = "uploaded"
    transcribing = "transcribing"
    indexed = "indexed"
    failed = "failed"


class RecordingCreate(BaseModel):
    """Payload the client sends after uploading audio to the signed URL."""

    audio_path: str = Field(..., description="gs:// path returned by the upload endpoint.")
    duration_sec: float = 0.0
    # The moment's date; may be back-dated. Defaults to today on the server if omitted.
    event_date: date | None = None
    title: str | None = None


class Chunk(BaseModel):
    id: str
    text: str
    start_sec: float = 0.0
    end_sec: float = 0.0
    embedding: list[float] = Field(default_factory=list)


class Recording(BaseModel):
    id: str
    uid: str
    event_date: date
    recorded_at: datetime = Field(default_factory=_utcnow)
    audio_path: str
    duration_sec: float = 0.0
    status: RecordingStatus = RecordingStatus.uploaded

    # Filled by the ingestion pipeline.
    transcript: str = ""          # original language / script
    language: str = ""            # detected language(s), e.g. "ta", "hi-en" (code-switching)
    transcript_en: str = ""       # optional canonical English translation
    title: str = ""
    summary: str = ""
    tags: list[str] = Field(default_factory=list)
    people: list[str] = Field(default_factory=list)
    places: list[str] = Field(default_factory=list)
    mood: str = ""
    is_milestone: bool = False

    created_at: datetime = Field(default_factory=_utcnow)
    updated_at: datetime = Field(default_factory=_utcnow)

    def public_dict(self) -> dict:
        """Serialize without embedding vectors (those live on chunks)."""
        return self.model_dump(mode="json")
