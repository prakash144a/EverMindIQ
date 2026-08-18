from __future__ import annotations

import logging
import uuid
from datetime import date, datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Query, Response, status
from pydantic import BaseModel

from app.core.activity import track_activity
from app.core.entitlements import max_text_chars, tier_for
from app.core.media import content_type_for_path
from app.core.security import CurrentUser, get_current_user
from app.models.admin import bucket_label
from app.models.recording import Recording, RecordingCreate, RecordingSource, TextMemoryCreate
from app.services.firestore import get_repository
from app.services.storage import get_storage
from app.services.tasks import enqueue_ingest

router = APIRouter(
    prefix="/recordings", tags=["recordings"], dependencies=[Depends(track_activity)]
)

log = logging.getLogger(__name__)


class RecordingView(BaseModel):
    recording: dict
    audio_url: str


class RecordingUpdate(BaseModel):
    """Fields the user can edit after ingestion. Omitted fields are left alone."""

    is_milestone: bool | None = None
    # Empty string unfiles. Filing is never tier-gated — only creating a journal
    # is — so a lapsed premium user can still move memories around.
    journal_id: str | None = None


def _resolve_journal(repo, uid: str, journal_id: str) -> str:
    """Validate a journal the caller wants to file into.

    An unknown id is a 404 rather than a silent write: a memory filed into a
    journal that does not exist would vanish from every journal view while
    still claiming to be filed.
    """
    if journal_id and repo.get_journal(uid, journal_id) is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Journal not found")
    return journal_id


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
        journal_id=_resolve_journal(repo, user.uid, body.journal_id),
    )
    repo.add_recording(rec)
    _count_recording_quietly(repo, user.uid, rec)
    enqueue_ingest(user.uid, rec.id)
    # Return the freshest state (indexed inline in mock mode).
    return repo.get_recording(user.uid, rec.id) or rec


@router.post("/text", response_model=Recording, status_code=status.HTTP_201_CREATED)
def create_text_memory(
    body: TextMemoryCreate,
    user: CurrentUser = Depends(get_current_user),
) -> Recording:
    """Save a typed memory — no upload, no audio, no transcription.

    The typed text *is* the transcript, so ingestion joins at enrichment and the
    memory ends up indexed and recallable exactly like a spoken one.
    """
    repo = get_repository()
    text = body.text.strip()
    # Literal codes: the named constants for 422 and 413 were renamed in
    # Starlette and the old spellings now warn. See `auth._require_email`.
    if not text:
        raise HTTPException(status_code=422, detail="Memory text is empty")

    tier = tier_for(repo, user.uid)
    limit = max_text_chars(tier)
    if len(text) > limit:
        # Structured so the client can say something specific. The app caps the
        # field at the same number; this is the backstop, not the primary gate.
        raise HTTPException(
            status_code=413,
            detail={"error": "text_too_long", "limit": limit, "tier": tier.value},
        )

    rec = Recording(
        id=uuid.uuid4().hex,
        uid=user.uid,
        event_date=body.event_date or date.today(),
        recorded_at=datetime.now(timezone.utc),
        source=RecordingSource.text,
        transcript=text,
        title=body.title or "",
        journal_id=_resolve_journal(repo, user.uid, body.journal_id),
    )
    repo.add_recording(rec)
    _count_recording_quietly(repo, user.uid, rec)
    enqueue_ingest(user.uid, rec.id)
    # Return the freshest state (indexed inline in mock mode).
    return repo.get_recording(user.uid, rec.id) or rec


@router.get("", response_model=list[Recording])
def list_recordings(
    date_from: date | None = Query(default=None),
    date_to: date | None = Query(default=None),
    journal_id: str | None = Query(
        default=None,
        description='Filter by journal. Omit for every memory; pass "" for unfiled ones only.',
    ),
    user: CurrentUser = Depends(get_current_user),
) -> list[Recording]:
    return get_repository().list_recordings(
        user.uid, date_from=date_from, date_to=date_to, journal_id=journal_id
    )


@router.get("/{recording_id}", response_model=RecordingView)
def get_recording(
    recording_id: str,
    user: CurrentUser = Depends(get_current_user),
) -> RecordingView:
    rec = get_repository().get_recording(user.uid, recording_id)
    if rec is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Recording not found")
    # A typed memory has no blob, so there is nothing to sign a URL for.
    audio_url = get_storage().signed_download_url(rec.audio_path) if rec.audio_path else ""
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
    if not rec.audio_path:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Audio not available")
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
    """Edit a recording's user-controlled fields: the milestone star and its journal."""
    repo = get_repository()
    rec = repo.get_recording(user.uid, recording_id)
    if rec is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Recording not found")
    if body.is_milestone is not None:
        rec.is_milestone = body.is_milestone
        rec.is_milestone_manual = True
    if body.journal_id is not None:
        rec.journal_id = _resolve_journal(repo, user.uid, body.journal_id)
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
    _uncount_recording_quietly(repo, user.uid, rec)
    if rec.audio_path:
        _delete_audio_quietly(rec.audio_path)


def _count_recording_quietly(repo, uid: str, rec: Recording) -> None:
    """Update the operator-facing counters for a new recording.

    Deliberately here and not in `pipeline/ingest.py`: Pub/Sub delivery is
    at-least-once, so ingestion can run twice for one recording and would
    double-count. This path runs exactly once per recording created.

    Wrapped because a statistics failure must never cost the user their
    recording — the memory is already stored by the time we get here.
    """
    try:
        repo.record_created(uid, rec.duration_sec, rec.recorded_at)
        day = rec.created_at.date()
        repo.bump_daily(day, "recordings")
        # A typed memory is not a zero-second recording. Letting it into the
        # duration series would quietly drag the average toward zero and pile
        # every one of them into the shortest bucket, corrupting the "how long
        # do people record for" statistic the console shows.
        if rec.source is not RecordingSource.text:
            repo.bump_daily(day, "recording_seconds", rec.duration_sec)
            repo.bump_daily(day, "duration_buckets", 1, bucket=bucket_label(rec.duration_sec))
    except Exception:  # pragma: no cover - bookkeeping must not fail the request
        log.exception("failed to count recording %s for uid %s", rec.id, uid)


def _uncount_recording_quietly(repo, uid: str, rec: Recording) -> None:
    """Reverse the counters. `max_duration_sec` is a high-water mark and is
    deliberately not decremented — see `services/stats.apply_recording_deleted`."""
    try:
        repo.record_deleted(uid, rec.duration_sec)
    except Exception:  # pragma: no cover - bookkeeping must not fail the request
        log.exception("failed to uncount recording %s for uid %s", rec.id, uid)


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
