from __future__ import annotations

import logging
import uuid
from datetime import date, datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, Query, Response, status
from pydantic import BaseModel, Field

from app.core.activity import track_activity
from app.core.entitlements import (
    edit_window_days,
    max_recording_seconds,
    max_recordings_per_month,
    max_text_chars,
    tier_and_voice_usage,
    tier_for,
)
from app.core.media import content_type_for_path
from app.core.security import CurrentUser, get_current_user
from app.models.admin import bucket_label
from app.models.recording import (
    MAX_TITLE_LEN,
    Recording,
    RecordingCreate,
    RecordingSource,
    RecordingStatus,
    TextMemoryCreate,
)
from app.services.firestore import get_repository
from app.services.gemini import get_gemini
from app.services.stats import month_resets_on
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
    """Fields the user can edit after ingestion. Omitted fields are left alone.

    There is deliberately no `summary` here. The summary is the AI's reading of
    the memory, so the way to change it is to change the memory: an edited
    `transcript` gets a new one written for it.
    """

    is_milestone: bool | None = None
    # Empty string unfiles. Filing is never tier-gated — only creating a journal
    # is — so a lapsed premium user can still move memories around.
    journal_id: str | None = None
    # A rename. Costs no AI call, and from then on the title is the user's:
    # ingestion only ever fills in a title that is missing.
    title: str | None = Field(default=None, max_length=MAX_TITLE_LEN)
    # The memory's own words: what was typed, or the transcript of what was
    # said. Changing them re-runs enrichment and indexing — see `update_recording`.
    transcript: str | None = None


# The recorder and the clock it is timed by are not the same thing: the app stops
# at the tier's limit but measures elapsed wall time around an async stop, so an
# honest 60-second recording routinely reports 60.4. Rejecting that would look
# like a bug, so the API allows a little slack and the app never relies on it.
_DURATION_GRACE_SEC = 2.0


def _check_recording_allowed(repo, uid: str, duration_sec: float) -> None:
    """Gate one new voice memory on the caller's tier: length, then monthly quota.

    Both are 4xx with a structured `detail` so the app can name the number rather
    than showing a status code. The app checks the same two limits before it opens
    the microphone; this is the backstop for a client that did not.

    The quota read and the increment that follows it are not one transaction, so
    two requests racing can both pass and take the account one over. That is
    accepted: the cost of a single extra recording is a fraction of a cent, and a
    transaction here would put a write barrier on the hottest path in the app.
    """
    tier, used = tier_and_voice_usage(repo, uid)

    max_sec = max_recording_seconds(tier)
    if duration_sec > max_sec + _DURATION_GRACE_SEC:
        raise HTTPException(
            status_code=413,
            detail={
                "error": "recording_too_long",
                "limit_sec": max_sec,
                "duration_sec": round(duration_sec, 1),
                "tier": tier.value,
            },
        )

    limit = max_recordings_per_month(tier)
    if used >= limit:
        raise HTTPException(
            status_code=429,
            detail={
                "error": "recording_quota",
                "limit": limit,
                "used": used,
                "resets_on": month_resets_on().isoformat(),
                "tier": tier.value,
            },
        )


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
    Gated by the caller's tier on both length and this month's quota — see
    `_check_recording_allowed`.
    """
    repo = get_repository()
    _check_recording_allowed(repo, user.uid, body.duration_sec)
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
    """Edit a recording's user-controlled fields.

    The star and the journal are plain field writes. So is the title. The
    memory's words are not: changing them sends the memory back through
    enrichment and indexing, which rewrites the summary and everything else the
    AI derived — but not the title, which already exists and so is kept.

    The title and the words can only be changed inside the edit window (see
    `_require_editable`). The star and the journal are organising rather than
    editing, and stay open for good.
    """
    repo = get_repository()
    rec = repo.get_recording(user.uid, recording_id)
    if rec is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Recording not found")

    # Every check runs before anything is changed: `rec` may be the stored
    # object itself, so a request refused halfway must not have half-applied.
    title = text = None
    if body.title is not None or body.transcript is not None:
        _require_editable(rec)
    if body.title is not None:
        title = body.title.strip()
        if not title:
            raise HTTPException(status_code=422, detail="Title is empty")
    if body.transcript is not None:
        text = _checked_new_text(repo, rec, body.transcript)
    journal_id = (
        _resolve_journal(repo, user.uid, body.journal_id) if body.journal_id is not None else None
    )

    if body.is_milestone is not None:
        rec.is_milestone = body.is_milestone
        rec.is_milestone_manual = True
    if journal_id is not None:
        rec.journal_id = journal_id
    retitled = title is not None and title != rec.title
    if title is not None:
        rec.title = title
    reworded = text is not None and text != rec.transcript
    if reworded:
        _apply_new_text(rec, text)

    rec.updated_at = datetime.now(timezone.utc)
    saved = repo.update_recording(rec)
    if saved is None:
        # Deleted between the read above and the write — from another device, or
        # from this one while the request was in flight. A 404 rather than a
        # resurrected memory: `update_recording` no longer creates, precisely so
        # that starring something cannot bring it back.
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Recording not found")

    if retitled or reworded:
        # An On This Day item carries the title and summary it was built from and
        # an insight was written over them, so both would go on showing the old
        # ones.
        _purge_derived_quietly(repo, user.uid, recording_id)
    if reworded:
        # The chunks are the old words, and recall answers from them. Dropped now
        # rather than left for ingestion to overwrite: if that run is slow or
        # fails, a memory that cannot be found yet is the honest state, and one
        # still answering with text its owner removed is not.
        repo.discard_chunks(user.uid, recording_id)
        enqueue_ingest(user.uid, recording_id)
        # Return the freshest state (re-indexed inline in mock mode).
        return repo.get_recording(user.uid, recording_id) or saved
    return saved


@router.post("/{recording_id}/title", response_model=Recording)
def regenerate_title(
    recording_id: str,
    user: CurrentUser = Depends(get_current_user),
) -> Recording:
    """Have the AI write a new title, replacing whatever the memory has now.

    The way back from a rename that was a mistake, and the way forward from an
    AI title nobody liked — each call asks for one different from the current
    one. Only the title: the words are unchanged, so the summary, the entities
    and the search index are all still right and none of them is touched.
    """
    repo = get_repository()
    rec = repo.get_recording(user.uid, recording_id)
    if rec is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Recording not found")
    _require_editable(rec)
    if not rec.transcript.strip():
        # A recording that never produced a transcript has nothing to title.
        raise HTTPException(status_code=422, detail="Memory has no text to title")

    summary_lang = repo.get_settings_doc(user.uid).summary_language
    title = get_gemini().title(rec.transcript, rec.language, summary_lang, avoid=rec.title)
    title = title.strip()[:MAX_TITLE_LEN].strip()
    if not title:
        raise HTTPException(status_code=502, detail="Could not generate a title")

    # Read again rather than writing back the copy from before the model call:
    # that took seconds, and the whole document is written, so anything changed
    # in the meantime — a star, a journal, a delete — would be undone.
    rec = repo.get_recording(user.uid, recording_id)
    if rec is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Recording not found")
    _require_editable(rec)
    rec.title = title
    rec.updated_at = datetime.now(timezone.utc)
    saved = repo.update_recording(rec)
    if saved is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Recording not found")
    _purge_derived_quietly(repo, user.uid, recording_id)
    return saved


def _require_editable(rec: Recording) -> None:
    """Refuse to change a memory's title or words when it is too late, or too soon.

    Too late is the edit window: a memory can be reworded and retitled for a few
    days after it is saved and then it is settled for good. Counted from when it
    was captured, not from the date it is *about* — a memory back-dated to last
    year was still written today. Checked first because it is the permanent
    answer; "still processing" is one the caller can simply wait out.

    Too soon is ingestion holding a copy. A run reads the recording, spends
    seconds in Gemini, and writes the whole document back — so an edit landing
    in that window would be silently overwritten by the run's older copy. A 409
    the app can explain is better than an edit that appears to save and then
    reverts.
    """
    days = edit_window_days()
    recorded_at = rec.recorded_at
    if recorded_at.tzinfo is None:
        recorded_at = recorded_at.replace(tzinfo=timezone.utc)
    if datetime.now(timezone.utc) - recorded_at >= timedelta(days=days):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail={"error": "edit_window_closed", "window_days": days},
        )
    if rec.status in (RecordingStatus.uploaded, RecordingStatus.transcribing):
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail={"error": "memory_processing", "status": rec.status.value},
        )


def _checked_new_text(repo, rec: Recording, new_text: str) -> str:
    """Validate replacement words for a memory and return them trimmed."""
    text = new_text.strip()
    if not text:
        raise HTTPException(status_code=422, detail="Memory text is empty")

    # The typed-memory cap, except that a memory already over it may still be
    # corrected at its current length: a transcript of a long recording, or text
    # written on a tier since lapsed, must not become uneditable.
    tier = tier_for(repo, rec.uid)
    limit = max(max_text_chars(tier), len(rec.transcript))
    if len(text) > limit:
        raise HTTPException(
            status_code=413,
            detail={"error": "text_too_long", "limit": limit, "tier": tier.value},
        )
    return text


def _apply_new_text(rec: Recording, text: str) -> None:
    """Replace a memory's words on `rec` and mark it for another ingestion run.

    Everything the AI derived from the old words is cleared here rather than
    left to be overwritten: until the new run lands (or if it fails) a summary
    and a list of people describing text that is no longer there would be wrong,
    and blank is not. The title stays — it exists, so it is the user's — and so
    does the star, which ingestion re-judges unless it was set by hand.
    """
    rec.transcript = text
    rec.transcript_edited = True
    # Not carried over: the rewrite may be in another language, and a stated
    # language is echoed back by enrichment rather than detected.
    rec.language = ""
    rec.transcript_en = ""
    rec.summary = ""
    rec.tags = []
    rec.people = []
    rec.places = []
    rec.mood = ""
    rec.status = RecordingStatus.uploaded


@router.delete("/{recording_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_recording(
    recording_id: str,
    user: CurrentUser = Depends(get_current_user),
) -> None:
    """Erase one memory and everything that was made from it.

    The app promises the user that nothing survives this and that we cannot get
    it back, so the deletion has to be as total as that sentence claims: the
    metadata, the chunks the search index is built from, the audio object, and
    the derived caches that copied the memory's words out of it. The order below
    is deliberate — see the comments — and each step is independent, so one
    failing never leaves an earlier one un-done.
    """
    repo = get_repository()
    # Read the audio path before the metadata goes away — it is the only record
    # of which blob to delete, and without this the object outlives the memory
    # the user asked us to forget.
    rec = repo.get_recording(user.uid, recording_id)
    if rec is None or not repo.delete_recording(user.uid, recording_id):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Recording not found")
    _uncount_recording_quietly(repo, user.uid, rec)
    _purge_derived_quietly(repo, user.uid, recording_id)
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
    is_voice = rec.source is not RecordingSource.text
    try:
        repo.record_created(uid, rec.duration_sec, rec.recorded_at, is_voice=is_voice)
        day = rec.created_at.date()
        repo.bump_daily(day, "recordings")
        # A typed memory is not a zero-second recording. Letting it into the
        # duration series would quietly drag the average toward zero and pile
        # every one of them into the shortest bucket, corrupting the "how long
        # do people record for" statistic the console shows.
        if is_voice:
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


def _purge_derived_quietly(repo, uid: str, recording_id: str) -> None:
    """Drop the caches built *from* this user's memories.

    An On This Day feed item carries the title and summary it was built from, and
    an insight is a narrative written over a range of memories — so both can go on
    showing a deleted memory's words back to the person who deleted it. That is
    the one failure this whole feature exists to prevent, so it is logged loudly:
    a memory that still reads back after being deleted is worse than a delete
    that reported an error.
    """
    try:
        repo.purge_derived(uid)
    except Exception:  # pragma: no cover - real-path failure
        log.exception(
            "failed to purge derived caches for uid %s after deleting %s", uid, recording_id
        )


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
