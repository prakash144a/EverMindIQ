from __future__ import annotations

import logging
import uuid
from datetime import date, datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Query, Response, status
from pydantic import BaseModel

from app.core.media import content_type_for_path
from app.core.security import CurrentUser, get_current_user
from app.models.recording import Recording, RecordingCreate
from app.services.firestore import get_repository
from app.services.storage import get_storage
from app.services.tasks import enqueue_ingest

router = APIRouter(prefix="/recordings", tags=["recordings"])

log = logging.getLogger(__name__)


class RecordingView(BaseModel):
    recording: dict
    audio_url: str


class RecordingUpdate(BaseModel):
    """Fields the user can edit after ingestion. Omitted fields are left alone."""

    is_milestone: bool | None = None


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


@router.get("/{recording_id}/audio")
def get_recording_audio(
    recording_id: str,
    user: CurrentUser = Depends(get_current_user),
) -> Response:
    """Stream the raw audio bytes for in-app playback.

    Serves through the backend (rather than handing out a signed URL) so playback works
    uniformly in mock and real modes and stays behind the same auth as the metadata.
    """
    rec = get_repository().get_recording(user.uid, recording_id)
    if rec is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Recording not found")
    data = get_storage().read_bytes(rec.audio_path)
    if not data:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Audio not available")
    return Response(content=data, media_type=content_type_for_path(rec.audio_path))


@router.patch("/{recording_id}", response_model=Recording)
def update_recording(
    recording_id: str,
    body: RecordingUpdate,
    user: CurrentUser = Depends(get_current_user),
) -> Recording:
    """Edit a recording's user-controlled fields (currently just the milestone star)."""
    repo = get_repository()
    rec = repo.get_recording(user.uid, recording_id)
    if rec is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Recording not found")
    if body.is_milestone is not None:
        rec.is_milestone = body.is_milestone
        rec.is_milestone_manual = True
    rec.updated_at = datetime.now(timezone.utc)
    return repo.update_recording(rec)


@router.delete("/{recording_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_recording(
    recording_id: str,
    user: CurrentUser = Depends(get_current_user),
) -> None:
    repo = get_repository()
    # Read the audio path before the metadata goes away — it is the only record
    # of which blob to delete, and without this the object outlives the memory
    # the user asked us to forget.
    rec = repo.get_recording(user.uid, recording_id)
    if rec is None or not repo.delete_recording(user.uid, recording_id):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Recording not found")
    _delete_audio_quietly(rec.audio_path)


def _delete_audio_quietly(audio_path: str) -> None:
    """Best-effort blob deletion.

    Metadata is deleted first, so a failure here leaves an orphaned object rather
    than a recording whose audio 404s. Logged loudly because that orphan is both a
    storage cost and data the user believes is gone.
    """
    try:
        get_storage().delete_object(audio_path)
    except Exception:  # pragma: no cover - real-path failure
        log.exception("failed to delete audio object %s", audio_path)
