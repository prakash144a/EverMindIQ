"""Ingestion worker: transcribe -> enrich -> chunk -> embed transcript -> index.

Triggered (real mode) by a Pub/Sub message after the client finishes uploading audio. Here it is a
plain function so the API can also run it inline in mock mode and tests can call it directly.

Only the **transcript** is embedded (not raw audio) — semantic memory search is a text problem. The
audio blob stays in GCS for playback/re-transcription.
"""

from __future__ import annotations

import re
import uuid
from datetime import datetime, timezone

from app.core.config import get_settings
from app.models.recording import Chunk, Recording, RecordingStatus
from app.services.embedding import get_embedder
from app.services.firestore import get_repository
from app.services.gemini import get_gemini
from app.services.storage import get_storage

_SENTENCE_RE = re.compile(r"(?<=[.!?।])\s+")


class RecordingNotFound(LookupError):
    """The message names a recording that no longer exists.

    Permanent, not transient — retrying can never help, so the Pub/Sub push
    handler acks instead of nacking. Happens when a recording is deleted before
    ingestion runs, or when a message outlives the data it referenced.
    """


def chunk_transcript(transcript: str, max_words: int = 60) -> list[str]:
    """Group sentences into ~max_words windows. Keeps chunks semantically coherent."""
    sentences = [s.strip() for s in _SENTENCE_RE.split(transcript.strip()) if s.strip()]
    if not sentences:
        return []
    chunks: list[str] = []
    current: list[str] = []
    count = 0
    for sent in sentences:
        words = len(sent.split())
        if current and count + words > max_words:
            chunks.append(" ".join(current))
            current, count = [], 0
        current.append(sent)
        count += words
    if current:
        chunks.append(" ".join(current))
    return chunks


def process_recording(uid: str, recording_id: str) -> Recording:
    repo = get_repository()
    settings = get_settings()
    rec = repo.get_recording(uid, recording_id)
    if rec is None:
        raise RecordingNotFound(f"recording {recording_id} not found for user {uid}")

    rec.status = RecordingStatus.transcribing
    rec.updated_at = datetime.now(timezone.utc)
    repo.update_recording(rec)

    try:
        gemini = get_gemini()
        audio_bytes = get_storage().read_bytes(rec.audio_path)
        transcript, language = gemini.transcribe(rec.audio_path, audio_bytes)

        answer_lang = repo.get_settings_doc(uid).answer_language
        enrich = gemini.enrich(transcript, language, answer_lang)

        rec.transcript = transcript
        rec.language = language
        rec.transcript_en = enrich.transcript_en
        rec.title = rec.title or enrich.title
        rec.summary = enrich.summary
        rec.tags = enrich.tags
        rec.people = enrich.people
        rec.places = enrich.places
        rec.mood = enrich.mood
        # A hand-picked star wins: Pub/Sub delivery is at-least-once, so this can
        # re-run for a recording the user has already curated.
        if not rec.is_milestone_manual:
            rec.is_milestone = enrich.is_milestone

        # Embed the transcript (and translation, if any) for cross-lingual recall.
        embedder = get_embedder()
        texts = chunk_transcript(transcript)
        if enrich.transcript_en and enrich.transcript_en != transcript:
            texts += chunk_transcript(enrich.transcript_en)
        vectors = embedder.embed_batch(texts) if texts else []
        chunks = [
            Chunk(id=uuid.uuid4().hex, text=t, embedding=v)
            for t, v in zip(texts, vectors)
        ]
        repo.save_chunks(uid, recording_id, chunks)

        rec.status = RecordingStatus.indexed
    except Exception:
        rec.status = RecordingStatus.failed
        rec.updated_at = datetime.now(timezone.utc)
        repo.update_recording(rec)
        raise

    rec.updated_at = datetime.now(timezone.utc)
    repo.update_recording(rec)
    _ = settings  # settings available for future real-mode Pub/Sub ack, etc.
    return rec
