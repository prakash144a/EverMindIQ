"""Per-user data repository.

Mock mode keeps everything in a process-wide in-memory store (shared by the API and the ingestion
worker) and implements vector search by brute-force cosine similarity. Real mode maps the same
operations onto Firestore documents under ``users/{uid}/...`` with Firestore Vector Search.

Every method is scoped by ``uid`` — the isolation boundary that mirrors the Firestore security rules.
"""

from __future__ import annotations

from datetime import date
from threading import RLock

from app.core.config import Settings, get_settings
from app.models.insight import Insight, InsightRange
from app.models.memory import MemoryFeed
from app.models.recording import Chunk, Recording
from app.models.user import UserSettings
from app.services.embedding import cosine


class SearchHit:
    __slots__ = ("chunk", "recording", "score")

    def __init__(self, chunk: Chunk, recording: Recording, score: float) -> None:
        self.chunk = chunk
        self.recording = recording
        self.score = score


class Repository:
    def __init__(self, settings: Settings | None = None) -> None:
        self.settings = settings or get_settings()
        self._lock = RLock()
        # uid -> settings
        self._users: dict[str, UserSettings] = {}
        # uid -> {recording_id -> Recording}
        self._recordings: dict[str, dict[str, Recording]] = {}
        # recording_id -> [Chunk]
        self._chunks: dict[str, list[Chunk]] = {}
        # uid -> {insight_id -> Insight}
        self._insights: dict[str, dict[str, Insight]] = {}
        # uid -> {yyyy-mm-dd -> MemoryFeed}
        self._feeds: dict[str, dict[str, MemoryFeed]] = {}

    # -- user settings -----------------------------------------------------
    def get_settings_doc(self, uid: str) -> UserSettings:
        with self._lock:
            return self._users.setdefault(uid, UserSettings())

    def save_settings_doc(self, uid: str, settings: UserSettings) -> UserSettings:
        with self._lock:
            self._users[uid] = settings
            return settings

    # -- recordings --------------------------------------------------------
    def add_recording(self, rec: Recording) -> Recording:
        with self._lock:
            self._recordings.setdefault(rec.uid, {})[rec.id] = rec
            return rec

    def get_recording(self, uid: str, recording_id: str) -> Recording | None:
        with self._lock:
            return self._recordings.get(uid, {}).get(recording_id)

    def update_recording(self, rec: Recording) -> Recording:
        with self._lock:
            self._recordings.setdefault(rec.uid, {})[rec.id] = rec
            return rec

    def list_recordings(
        self,
        uid: str,
        date_from: date | None = None,
        date_to: date | None = None,
    ) -> list[Recording]:
        with self._lock:
            items = list(self._recordings.get(uid, {}).values())
        items = [r for r in items if _in_range(r.event_date, date_from, date_to)]
        items.sort(key=lambda r: (r.event_date, r.recorded_at), reverse=True)
        return items

    def delete_recording(self, uid: str, recording_id: str) -> bool:
        with self._lock:
            existed = self._recordings.get(uid, {}).pop(recording_id, None) is not None
            self._chunks.pop(recording_id, None)
            return existed

    # -- chunks / vectors --------------------------------------------------
    def save_chunks(self, recording_id: str, chunks: list[Chunk]) -> None:
        with self._lock:
            self._chunks[recording_id] = chunks

    def vector_search(
        self,
        uid: str,
        query_vec: list[float],
        top_k: int,
        date_from: date | None = None,
        date_to: date | None = None,
    ) -> list[SearchHit]:
        with self._lock:
            recs = dict(self._recordings.get(uid, {}))
            chunks_by_rec = {rid: list(cs) for rid, cs in self._chunks.items() if rid in recs}
        hits: list[SearchHit] = []
        for rid, chunks in chunks_by_rec.items():
            rec = recs[rid]
            if not _in_range(rec.event_date, date_from, date_to):
                continue
            for ch in chunks:
                hits.append(SearchHit(ch, rec, cosine(query_vec, ch.embedding)))
        hits.sort(key=lambda h: h.score, reverse=True)
        return hits[:top_k]

    # -- insights ----------------------------------------------------------
    def save_insight(self, uid: str, insight: Insight) -> Insight:
        with self._lock:
            self._insights.setdefault(uid, {})[insight.id] = insight
            return insight

    def get_cached_insight(self, uid: str, insight_id: str) -> Insight | None:
        with self._lock:
            return self._insights.get(uid, {}).get(insight_id)

    # -- memory feed -------------------------------------------------------
    def save_feed(self, uid: str, feed: MemoryFeed) -> MemoryFeed:
        with self._lock:
            self._feeds.setdefault(uid, {})[feed.for_date.isoformat()] = feed
            return feed

    def get_feed(self, uid: str, for_date: date) -> MemoryFeed | None:
        with self._lock:
            return self._feeds.get(uid, {}).get(for_date.isoformat())

    # -- account deletion (purge) -----------------------------------------
    def delete_user(self, uid: str) -> None:
        with self._lock:
            for rid in list(self._recordings.get(uid, {})):
                self._chunks.pop(rid, None)
            self._recordings.pop(uid, None)
            self._insights.pop(uid, None)
            self._feeds.pop(uid, None)
            self._users.pop(uid, None)


def _in_range(d: date, lo: date | None, hi: date | None) -> bool:
    if lo and d < lo:
        return False
    if hi and d > hi:
        return False
    return True


# Note: the real Firestore-backed Repository would subclass/replace this with google-cloud-firestore
# reads/writes and Firestore Vector Search queries. Kept behind the same interface so callers and the
# ingestion worker are storage-agnostic.

_repo_singleton: Repository | None = None


def get_repository() -> Repository:
    global _repo_singleton
    if _repo_singleton is None:
        _repo_singleton = Repository()
    return _repo_singleton


def reset_repository() -> None:
    """Test helper: drop all in-memory state."""
    global _repo_singleton
    _repo_singleton = Repository()
