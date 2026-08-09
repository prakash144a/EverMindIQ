from __future__ import annotations

import uuid
from datetime import date, datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Query, status
from pydantic import BaseModel

from app.core.security import CurrentUser, get_current_user
from app.models.recording import Recording, RecordingCreate
from app.services.firestore import get_repository
from app.services.storage import get_storage
from app.services.tasks import enqueue_ingest

router = APIRouter(prefix="/recordings", tags=["recordings"])


class RecordingView(BaseModel):
    recording: dict
    audio_url: str


@router.post("", response_model=Recording, status_code=status.HTTP_201_CREATED)
def create_recording(
    body: RecordingCreate,
    user: CurrentUser = Depends(get_current_user),
) -> Recording:
    """Register an uploaded audio file and kick off ingestion.

    `event_date` defaults to today but may be back-dated to log a past moment.
    """
    repo = get_repository()
    rec = Recording(
        id=uuid.uuid4().hex,
        uid=user.uid,
        event_date=body.event_date or date.today(),
        recorded_at=datetime.now(timezone.utc),
        audio_path=body.audio_path,
        duration_sec=body.duration_sec,
        title=body.title or "",
    )
    repo.add_recording(rec)
    enqueue_ingest(user.uid, rec.id)
    # Return the freshest state (indexed inline in mock mode).
    return repo.get_recording(user.uid, rec.id) or rec


@router.get("", response_model=list[Recording])
def list_recordings(
    date_from: date | None = Query(default=None),
    date_to: date | None = Query(default=None),
    user: CurrentUser = Depends(get_current_user),
) -> list[Recording]:
    return get_repository().list_recordings(user.uid, date_from=date_from, date_to=date_to)


@router.get("/{recording_id}", response_model=RecordingView)
def get_recording(
    recording_id: str,
    user: CurrentUser = Depends(get_current_user),
) -> RecordingView:
    rec = get_repository().get_recording(user.uid, recording_id)
    if rec is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Recording not found")
    audio_url = get_storage().signed_download_url(rec.audio_path)
    return RecordingView(recording=rec.public_dict(), audio_url=audio_url)


@router.delete("/{recording_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_recording(
    recording_id: str,
    user: CurrentUser = Depends(get_current_user),
) -> None:
    if not get_repository().delete_recording(user.uid, recording_id):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Recording not found")
