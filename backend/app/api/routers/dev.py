"""Developer/testing helpers. Only mounted in mock mode."""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from app.core.security import CurrentUser, get_current_user
from app.models.user import normalize_email
from app.services.gemini import seed_transcript
from app.services.otp import peek_mock_code

router = APIRouter(prefix="/dev", tags=["dev"])


class SeedTranscript(BaseModel):
    audio_path: str
    transcript: str
    language: str = "en"


@router.post("/seed-transcript", status_code=204)
def seed(body: SeedTranscript, _: CurrentUser = Depends(get_current_user)) -> None:
    """Attach a known transcript to a (mock) audio object so ingestion has something to index."""
    seed_transcript(body.audio_path, body.transcript, body.language)


class OtpPeek(BaseModel):
    email: str


class LastOtp(BaseModel):
    email: str
    code: str


@router.post("/last-otp", response_model=LastOtp)
def last_otp(body: OtpPeek, _: CurrentUser = Depends(get_current_user)) -> LastOtp:
    """Reveal the pending code for an address.

    Mock mode sends no email, so without this the sign-up flow can't be driven
    end to end locally. This whole router is mounted only when
    `effective_mock` is true, so it can never leak a real user's code.
    """
    email = normalize_email(body.email)
    code = peek_mock_code(email)
    if code is None:
        raise HTTPException(status_code=404, detail="No code pending for that address")
    return LastOtp(email=email, code=code)
