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


class RecordingSource(str, Enum):
    """How the memory was captured.

    A `text` memory has no audio blob and skips transcription; it joins the
    ingestion pipeline at enrichment. Everything downstream of that is identical,
    so the two kinds are one collection, not two.
    """

    voice = "voice"
    text = "text"


class RecordingCreate(BaseModel):
    """Payload the client sends after uploading audio to the signed URL."""

    audio_path: str = Field(..., description="gs:// path returned by the upload endpoint.")
    duration_sec: float = 0.0
    # The moment's date; may be back-dated. Defaults to today on the server if omitted.
    event_date: date | None = None
    title: str | None = None
    # Optional: the journal chosen on the record screen. Filing is never
    # tier-gated — only creating a journal is.
    journal_id: str = ""


class TextMemoryCreate(BaseModel):
    """Payload for a typed memory.

    Deliberately not a variant of [RecordingCreate] with an optional `audio_path`:
    on the voice path an upload that produced no path is a bug worth rejecting,
    and collapsing the two would lose that.

    The length cap is not declared here because it depends on the caller's tier —
    see `core/entitlements`.
    """

    text: str = Field(..., min_length=1)
    event_date: date | None = None
    title: str | None = None
    journal_id: str = ""


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
    # Empty for a typed memory, which has no blob. Every audio-serving path
    # checks this rather than assuming a path exists.
    audio_path: str = ""
    duration_sec: float = 0.0
    status: RecordingStatus = RecordingStatus.uploaded
    # Defaulting to `voice` keeps every document written before typed memories
    # existed valid on read (`doc_to_recording` is `Recording(**doc)`).
    source: RecordingSource = RecordingSource.voice
    # Which journal this memory is filed in; empty means unfiled. A default is
    # mandatory for the same reason `source` has one: `doc_to_recording` is
    # `Recording(**doc)`, so every document written before journals existed has
    # to stay readable.
    journal_id: str = ""

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
    # Set when the user stars/unstars by hand; ingestion then leaves the flag alone.
    is_milestone_manual: bool = False

    created_at: datetime = Field(default_factory=_utcnow)
    updated_at: datetime = Field(default_factory=_utcnow)

    def public_dict(self) -> dict:
        """Serialize without embedding vectors (those live on chunks)."""
        return self.model_dump(mode="json")
