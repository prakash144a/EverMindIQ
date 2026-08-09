"""Developer/testing helpers. Only mounted in mock mode."""

from __future__ import annotations

from fastapi import APIRouter, Depends
from pydantic import BaseModel

from app.core.security import CurrentUser, get_current_user
from app.services.gemini import seed_transcript

router = APIRouter(prefix="/dev", tags=["dev"])


class SeedTranscript(BaseModel):
    audio_path: str
    transcript: str
    language: str = "en"


@router.post("/seed-transcript", status_code=204)
def seed(body: SeedTranscript, _: CurrentUser = Depends(get_current_user)) -> None:
    """Attach a known transcript to a (mock) audio object so ingestion has something to index."""
    seed_transcript(body.audio_path, body.transcript, body.language)
