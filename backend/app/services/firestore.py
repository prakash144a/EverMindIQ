"""Per-user data repository.

Mock mode keeps everything in a process-wide in-memory store (shared by the API and the ingestion
worker) and implements vector search by brute-force cosine similarity. Real mode maps the same
operations onto Firestore documents under ``users/{uid}/...`` with Firestore Vector Search.

Every method is scoped by ``uid`` — the isolation boundary that mirrors the Firestore security
rules. The exception is the admin plane at the bottom, which reads across users and lives in
top-level collections no client can reach.
"""

from __future__ import annotations

from datetime import date, datetime, timedelta, timezone
from threading import RLock
from typing import Callable, TypeVar

from app.core.config import Settings, get_settings
from app.models.admin import (
    AdminAuditEntry,
    DailyStats,
    DeviceAccount,
    DeviceInfo,
    FeedbackTriage,
)
from app.models.feedback import Feedback
from app.models.insight import Insight
from app.models.journal import Journal
from app.models.memory import MemoryFeed
from app.models.recording import Chunk, Recording, RecordingStatus
from app.models.user import (
    OtpChallenge,
    UserProfile,
    UserSettings,
    UserStats,
    UserTier,
    normalize_email,
)
from app.services import stats as stats_ops
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
        # uid -> {journal_id -> Journal}
        self._journals: dict[str, dict[str, Journal]] = {}
        # uid -> {insight_id -> Insight}
        self._insights: dict[str, dict[str, Insight]] = {}
        # uid -> {yyyy-mm-dd -> MemoryFeed}
        self._feeds: dict[str, dict[str, MemoryFeed]] = {}
        # uid -> {feedback_id -> Feedback}
        self._feedback: dict[str, dict[str, Feedback]] = {}
        # uid -> profile
        self._profiles: dict[str, UserProfile] = {}
        # normalized email -> uid
        self._email_index: dict[str, str] = {}
        # normalized email -> pending OTP
        self._otps: dict[str, OtpChallenge] = {}
        # -- admin plane (mirrors the top-level Firestore collections) ------
        # uid -> stats
        self._stats: dict[str, UserStats] = {}
        # install_id -> device
        self._devices: dict[str, DeviceInfo] = {}
        # install_id -> {uid -> account}
        self._device_accounts: dict[str, dict[str, DeviceAccount]] = {}
        # yyyy-mm-dd -> rollup
        self._daily: dict[str, DailyStats] = {}
        # feedback_id -> triage
        self._triage: dict[str, FeedbackTriage] = {}
        self._audit: list[AdminAuditEntry] = []

    # -- user settings -----------------------------------------------------
    def get_settings_doc(self, uid: str) -> UserSettings:
        with self._lock:
            return self._users.setdefault(uid, UserSettings())

    def save_settings_doc(self, uid: str, settings: UserSettings) -> UserSettings:
        with self._lock:
            self._users[uid] = settings
            return settings

    # -- profile / identity ------------------------------------------------
    def get_profile(self, uid: str) -> UserProfile | None:
        with self._lock:
            return self._profiles.get(uid)

    def save_profile(self, uid: str, profile: UserProfile) -> UserProfile:
        with self._lock:
            self._profiles[uid] = profile
            return profile

    def uid_for_email(self, email: str) -> str | None:
        with self._lock:
            return self._email_index.get(normalize_email(email))

    def set_email_index(self, email: str, uid: str) -> None:
        with self._lock:
            self._email_index[normalize_email(email)] = uid

    # -- OTP challenges ----------------------------------------------------
    def get_otp(self, email: str) -> OtpChallenge | None:
        with self._lock:
            return self._otps.get(normalize_email(email))

    def save_otp(self, challenge: OtpChallenge) -> OtpChallenge:
        with self._lock:
            self._otps[normalize_email(challenge.email)] = challenge
            return challenge

    def delete_otp(self, email: str) -> None:
        with self._lock:
            self._otps.pop(normalize_email(email), None)

    # -- journals ----------------------------------------------------------
    def list_journals(self, uid: str) -> list[Journal]:
        with self._lock:
            items = list(self._journals.get(uid, {}).values())
        items.sort(key=lambda j: j.name.casefold())
        return items

    def get_journal(self, uid: str, journal_id: str) -> Journal | None:
        with self._lock:
            return self._journals.get(uid, {}).get(journal_id)

    def save_journal(self, uid: str, journal: Journal) -> Journal:
        with self._lock:
            self._journals.setdefault(uid, {})[journal.id] = journal
            return journal

    def delete_journal(self, uid: str, journal_id: str) -> int:
        """Delete the journal and unfile its memories; return how many moved.

        Deliberately never deletes a memory. Losing a journal is a filing
        decision; losing what was filed in it would be losing a life.
        """
        with self._lock:
            self._journals.get(uid, {}).pop(journal_id, None)
            unfiled = 0
            for rec in self._recordings.get(uid, {}).values():
                if rec.journal_id == journal_id:
                    rec.journal_id = ""
                    unfiled += 1
            return unfiled

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
        journal_id: str | None = None,
    ) -> list[Recording]:
        with self._lock:
            items = list(self._recordings.get(uid, {}).values())
        items = [
            r
            for r in items
            if _in_range(r.event_date, date_from, date_to) and _matches_journal(r, journal_id)
        ]
        items.sort(key=lambda r: (r.event_date, r.recorded_at), reverse=True)
        return items

    def delete_recording(self, uid: str, recording_id: str) -> bool:
        with self._lock:
            existed = self._recordings.get(uid, {}).pop(recording_id, None) is not None
            self._chunks.pop(recording_id, None)
            return existed

    # -- feedback ----------------------------------------------------------
    def add_feedback(self, item: Feedback) -> Feedback:
        with self._lock:
            self._feedback.setdefault(item.uid, {})[item.id] = item
            return item

    def list_feedback(self, uid: str) -> list[Feedback]:
        with self._lock:
            items = list(self._feedback.get(uid, {}).values())
        items.sort(key=lambda f: f.created_at, reverse=True)
        return items

    # -- chunks / vectors --------------------------------------------------
    def save_chunks(self, uid: str, recording_id: str, chunks: list[Chunk]) -> None:
        # `uid` is unused here (recording ids are globally unique) but is part of
        # the interface so the Firestore implementation can address the document.
        del uid
        with self._lock:
            self._chunks[recording_id] = chunks

    def vector_search(
        self,
        uid: str,
        query_vec: list[float],
        top_k: int,
        date_from: date | None = None,
        date_to: date | None = None,
        journal_id: str | None = None,
    ) -> list[SearchHit]:
        with self._lock:
            recs = dict(self._recordings.get(uid, {}))
            chunks_by_rec = {rid: list(cs) for rid, cs in self._chunks.items() if rid in recs}
        hits: list[SearchHit] = []
        for rid, chunks in chunks_by_rec.items():
            rec = recs[rid]
            if not _in_range(rec.event_date, date_from, date_to):
                continue
            if not _matches_journal(rec, journal_id):
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

    # ==================================================================
    # Admin plane
    # ==================================================================
    def get_user_stats(self, uid: str) -> UserStats | None:
        with self._lock:
            return self._stats.get(uid)

    def save_user_stats(self, stats: UserStats) -> UserStats:
        with self._lock:
            self._stats[stats.uid] = stats
            return stats

    def ensure_user_stats(self, uid: str) -> tuple[UserStats, bool]:
        """Return (stats, created). Creating on first sight is what guarantees
        every active account is listable — see `touch_activity`."""
        with self._lock:
            existing = self._stats.get(uid)
            if existing is not None:
                return existing, False
            created = stats_ops.new_stats(uid)
            self._stats[uid] = created
            return created, True

    def touch_activity(
        self, uid: str, install_id: str, platform: str, app_version: str
    ) -> tuple[bool, bool]:
        """Record activity. Returns (is_new_user, is_first_activity_today)."""
        with self._lock:
            stats, created = self.ensure_user_stats(uid)
            new_day = stats_ops.apply_activity(stats, install_id, platform, app_version)
            self._stats[uid] = stats
            if install_id:
                self._link_device(uid, install_id, platform, app_version, stats)
            return created, (created or new_day)

    def _link_device(
        self,
        uid: str,
        install_id: str,
        platform: str,
        app_version: str,
        stats: UserStats,
    ) -> None:
        """Associate an account with a device. Caller holds the lock."""
        now = datetime.now(timezone.utc)
        device = self._devices.get(install_id)
        if device is None:
            device = DeviceInfo(install_id=install_id, first_seen_at=now, last_seen_at=now)
        device.last_seen_at = now
        if platform:
            device.platform = platform
        if app_version:
            device.app_version = app_version

        accounts = self._device_accounts.setdefault(install_id, {})
        account = accounts.get(uid)
        if account is None:
            account = DeviceAccount(uid=uid, install_id=install_id, first_seen_at=now)
        account.last_seen_at = now
        account.email = stats.email
        account.preferred_name = stats.preferred_name
        accounts[uid] = account

        device.account_count = len(accounts)
        self._devices[install_id] = device

    def record_created(self, uid: str, duration_sec: float, recorded_at: datetime) -> UserStats:
        with self._lock:
            stats, _ = self.ensure_user_stats(uid)
            stats_ops.apply_recording_created(stats, duration_sec, recorded_at)
            self._stats[uid] = stats
            return stats

    def record_deleted(self, uid: str, duration_sec: float) -> UserStats | None:
        with self._lock:
            stats = self._stats.get(uid)
            if stats is None:
                return None
            stats_ops.apply_recording_deleted(stats, duration_sec)
            self._stats[uid] = stats
            return stats

    def bump_feedback_count(self, uid: str) -> None:
        with self._lock:
            stats, _ = self.ensure_user_stats(uid)
            stats.feedback_count += 1
            self._stats[uid] = stats

    def sync_user_identity(
        self, uid: str, preferred_name: str, email: str, email_verified: bool
    ) -> UserStats:
        with self._lock:
            stats, _ = self.ensure_user_stats(uid)
            stats_ops.apply_identity(stats, preferred_name, email, email_verified)
            self._stats[uid] = stats
            # Keep the device rows readable: they show the account's name/email.
            for accounts in self._device_accounts.values():
                if uid in accounts:
                    accounts[uid].email = email
                    accounts[uid].preferred_name = preferred_name
            return stats

    def set_tier(
        self, uid: str, tier: UserTier | None, note: str | None, admin_uid: str
    ) -> UserStats | None:
        with self._lock:
            stats = self._stats.get(uid)
            if stats is None:
                return None
            stats_ops.apply_tier(stats, tier, note, admin_uid)
            self._stats[uid] = stats
            return stats

    def recompute_user_stats(self, uid: str) -> UserStats | None:
        with self._lock:
            stats = self._stats.get(uid)
            if stats is None:
                return None
            recordings = list(self._recordings.get(uid, {}).values())
            feedback_count = len(self._feedback.get(uid, {}))
            stats_ops.recompute(stats, recordings, feedback_count)
            self._stats[uid] = stats
            return stats

    def list_user_stats(
        self,
        sort: str = "last_active_at",
        order: str = "desc",
        limit: int = 50,
        cursor: str | None = None,
        tier: str | None = None,
        platform: str | None = None,
        query: str | None = None,
    ) -> tuple[list[UserStats], str | None]:
        with self._lock:
            rows = list(self._stats.values())
        rows = [r for r in rows if _stats_matches(r, tier, platform, query)]
        rows.sort(key=lambda s: (_sort_key(s, sort), s.uid), reverse=(order == "desc"))
        return _paginate(rows, limit, cursor, lambda s: s.uid)

    def count_user_stats(
        self, tier: str | None = None, active_since: datetime | None = None
    ) -> int:
        with self._lock:
            rows = list(self._stats.values())
        return sum(
            1
            for r in rows
            if (tier is None or r.tier.value == tier)
            and (active_since is None or r.last_active_at >= active_since)
        )

    def global_summary(self) -> dict:
        with self._lock:
            rows = list(self._stats.values())
            devices = list(self._devices.values())
            failed = sum(
                1
                for recs in self._recordings.values()
                for r in recs.values()
                if r.status == RecordingStatus.failed
            )
        now = datetime.now(timezone.utc)
        return {
            "users_total": len(rows),
            "users_premium": sum(1 for r in rows if r.tier == UserTier.premium),
            "users_with_email": sum(1 for r in rows if r.email),
            "users_anonymous": sum(1 for r in rows if not r.email),
            "recordings_total": sum(r.recordings_count for r in rows),
            "total_duration_sec": round(sum(r.total_duration_sec for r in rows), 3),
            "max_duration_sec": max((r.max_duration_sec for r in rows), default=0.0),
            "devices_total": len(devices),
            "multi_account_devices": sum(1 for d in devices if d.account_count > 1),
            "active_1d": _active_since(rows, now - timedelta(days=1)),
            "active_7d": _active_since(rows, now - timedelta(days=7)),
            "active_30d": _active_since(rows, now - timedelta(days=30)),
            "feedback_total": sum(r.feedback_count for r in rows),
            "failed_recordings": failed,
        }

    # -- devices -----------------------------------------------------------
    def get_device(self, install_id: str) -> DeviceInfo | None:
        with self._lock:
            return self._devices.get(install_id)

    def list_devices(
        self, limit: int = 50, cursor: str | None = None
    ) -> tuple[list[DeviceInfo], str | None]:
        with self._lock:
            rows = list(self._devices.values())
        rows.sort(key=lambda d: (d.last_seen_at, d.install_id), reverse=True)
        return _paginate(rows, limit, cursor, lambda d: d.install_id)

    def list_device_accounts(self, install_id: str) -> list[DeviceAccount]:
        with self._lock:
            accounts = list(self._device_accounts.get(install_id, {}).values())
        accounts.sort(key=lambda a: a.last_seen_at, reverse=True)
        return accounts

    def list_devices_for_user(self, uid: str) -> list[DeviceInfo]:
        with self._lock:
            ids = [i for i, accts in self._device_accounts.items() if uid in accts]
            devices = [self._devices[i] for i in ids if i in self._devices]
        devices.sort(key=lambda d: d.last_seen_at, reverse=True)
        return devices

    # -- daily rollups -----------------------------------------------------
    def bump_daily(
        self, day: date, field: str, amount: float = 1, bucket: str | None = None
    ) -> DailyStats:
        with self._lock:
            key = day.isoformat()
            entry = self._daily.get(key) or DailyStats(day=day)
            if bucket is not None:
                entry.duration_buckets[bucket] = entry.duration_buckets.get(bucket, 0) + int(amount)
            else:
                setattr(entry, field, getattr(entry, field) + amount)
            self._daily[key] = entry
            return entry

    def list_daily(self, date_from: date, date_to: date) -> list[DailyStats]:
        with self._lock:
            rows = [d for d in self._daily.values() if date_from <= d.day <= date_to]
        rows.sort(key=lambda d: d.day)
        return rows

    # -- feedback triage ---------------------------------------------------
    def list_all_feedback(
        self,
        limit: int = 50,
        cursor: str | None = None,
        kind: str | None = None,
        platform: str | None = None,
    ) -> tuple[list[Feedback], str | None]:
        with self._lock:
            rows = [f for items in self._feedback.values() for f in items.values()]
        if kind:
            rows = [f for f in rows if f.kind.value == kind]
        if platform:
            rows = [f for f in rows if f.platform == platform]
        rows.sort(key=lambda f: (f.created_at, f.id), reverse=True)
        return _paginate(rows, limit, cursor, lambda f: f.id)

    def get_triage(self, feedback_id: str) -> FeedbackTriage | None:
        with self._lock:
            return self._triage.get(feedback_id)

    def save_triage(self, triage: FeedbackTriage) -> FeedbackTriage:
        with self._lock:
            self._triage[triage.feedback_id] = triage
            return triage

    # -- pipeline health ---------------------------------------------------
    def list_failed_recordings(self, limit: int = 50) -> list[Recording]:
        with self._lock:
            rows = [
                r
                for recs in self._recordings.values()
                for r in recs.values()
                if r.status in (RecordingStatus.failed, RecordingStatus.transcribing)
            ]
        rows.sort(key=lambda r: r.updated_at, reverse=True)
        return rows[:limit]

    # -- audit -------------------------------------------------------------
    def add_audit(self, entry: AdminAuditEntry) -> AdminAuditEntry:
        with self._lock:
            self._audit.append(entry)
            return entry

    def list_audit(self, limit: int = 100) -> list[AdminAuditEntry]:
        with self._lock:
            return sorted(self._audit, key=lambda e: e.at, reverse=True)[:limit]

    # -- merge (restore after reinstall) -----------------------------------
    def merge_user(self, src_uid: str, dst_uid: str) -> dict[str, int]:
        """Move everything owned by `src_uid` onto `dst_uid`; return what moved.

        Used when someone reinstalls, records a few memories under the throwaway
        anonymous identity, then verifies the email of an existing account. The
        account's own settings and profile win; only content moves.

        Callers MUST have proven the caller controls both sides — see
        `app/api/routers/auth.py`. Nothing here checks that.
        """
        if src_uid == dst_uid:
            return {"recordings": 0, "journals": 0, "feedback": 0, "insights": 0, "feeds": 0}
        with self._lock:
            # Journals move before the recordings that point at them. Ids are
            # uuids, so nothing can collide, and `journal_id` is denormalized
            # onto each recording — a restored memory must come back still
            # filed where its owner filed it.
            moved_journals = self._journals.pop(src_uid, {})
            self._journals.setdefault(dst_uid, {}).update(moved_journals)

            moved_recs = self._recordings.pop(src_uid, {})
            for rec in moved_recs.values():
                # uid is denormalized onto the document, so re-bucketing isn't enough.
                rec.uid = dst_uid
            self._recordings.setdefault(dst_uid, {}).update(moved_recs)

            moved_feedback = self._feedback.pop(src_uid, {})
            for item in moved_feedback.values():
                item.uid = dst_uid
            self._feedback.setdefault(dst_uid, {}).update(moved_feedback)

            moved_insights = self._insights.pop(src_uid, {})
            self._insights.setdefault(dst_uid, {}).update(moved_insights)

            # Feeds are a derived cache keyed by date; drop rather than merge so
            # the next read rebuilds them over the combined set.
            moved_feeds = self._feeds.pop(src_uid, {})
            self._feeds.pop(dst_uid, None)

            self._users.pop(src_uid, None)
            self._profiles.pop(src_uid, None)

            # Fold the account's history onto the session that now owns it. See
            # `stats.merge_stats` for why the direction matters so much.
            src_stats = self._stats.pop(src_uid, None)
            if src_stats is not None:
                dst_stats, _ = self.ensure_user_stats(dst_uid)
                self._stats[dst_uid] = stats_ops.merge_stats(src_stats, dst_stats)
            for accounts in self._device_accounts.values():
                accounts.pop(src_uid, None)
            self._refresh_device_counts()
        # Chunks are keyed by recording id, which is preserved, so they follow.
        return {
            "recordings": len(moved_recs),
            "journals": len(moved_journals),
            "feedback": len(moved_feedback),
            "insights": len(moved_insights),
            "feeds": len(moved_feeds),
        }

    # -- account deletion (purge) -----------------------------------------
    def delete_user(self, uid: str) -> None:
        with self._lock:
            for rid in list(self._recordings.get(uid, {})):
                self._chunks.pop(rid, None)
            self._recordings.pop(uid, None)
            self._journals.pop(uid, None)
            self._insights.pop(uid, None)
            self._feeds.pop(uid, None)
            self._feedback.pop(uid, None)
            self._users.pop(uid, None)
            profile = self._profiles.pop(uid, None)
            if profile and profile.email:
                self._email_index.pop(normalize_email(profile.email), None)
            # The install id is stored here and on the device link, and nowhere
            # else — deleting both is what makes it genuinely deletable.
            self._stats.pop(uid, None)
            for accounts in self._device_accounts.values():
                accounts.pop(uid, None)
            self._refresh_device_counts()

    def _refresh_device_counts(self) -> None:
        """Recount accounts per device, and drop devices nobody uses. Caller holds the lock."""
        for install_id, accounts in list(self._device_accounts.items()):
            if not accounts:
                self._device_accounts.pop(install_id, None)
                self._devices.pop(install_id, None)
                continue
            device = self._devices.get(install_id)
            if device is not None:
                device.account_count = len(accounts)


_T = TypeVar("_T")

# The highest private-use code point. Firestore has no "starts with" operator,
# so a prefix search is expressed as the range [q, q + PREFIX_END). Spelled as
# an escape rather than the literal character, which is invisible in an editor.
PREFIX_END = "\uf8ff"

# Fields the admin user list may sort by. Constrained because each one needs a
# matching Firestore index; an unbounded sort param would 500 in production
# against a query no index supports.
SORTABLE = (
    "last_active_at",
    "created_at",
    "recordings_count",
    "total_duration_sec",
    "max_duration_sec",
    "email",
)


def _sort_key(stats: UserStats, sort: str):
    if sort not in SORTABLE:
        sort = "last_active_at"
    return getattr(stats, sort)


def _stats_matches(
    stats: UserStats, tier: str | None, platform: str | None, query: str | None
) -> bool:
    if tier and stats.tier.value != tier:
        return False
    if platform and stats.platform != platform:
        return False
    if query:
        # Prefix, not substring: Firestore can do `>= q AND < q + ` with an
        # index, and cannot do substring search at any price. Matching the real
        # backend's capability here keeps the mock honest.
        q = query.strip().lower()
        haystacks = (stats.email.lower(), stats.preferred_name_lower, stats.uid.lower())
        if not any(h.startswith(q) for h in haystacks):
            return False
    return True


def _paginate(
    rows: list[_T], limit: int, cursor: str | None, key: Callable[[_T], str]
) -> tuple[list[_T], str | None]:
    """Slice `rows` after `cursor`, returning the page and the next cursor.

    The cursor is the previous page's last document id, so a row inserted or
    removed between pages shifts the boundary rather than corrupting it.
    """
    from app.models.admin import decode_cursor, encode_cursor

    after = decode_cursor(cursor)
    if after is not None:
        ids = [key(r) for r in rows]
        if after in ids:
            rows = rows[ids.index(after) + 1 :]
    page = rows[:limit]
    next_cursor = encode_cursor(key(page[-1])) if len(rows) > limit and page else None
    return page, next_cursor


def _active_since(rows: list[UserStats], cutoff: datetime) -> int:
    return sum(1 for r in rows if r.last_active_at >= cutoff)


def _matches_journal(rec: Recording, journal_id: str | None) -> bool:
    """Whether `rec` passes a journal filter.

    `None` means no filter at all; `""` means *unfiled only*. Collapsing those
    two into one falsy check would make "show me what I never filed"
    indistinguishable from "show me everything", which is the whole point of
    the Unfiled row.
    """
    return journal_id is None or rec.journal_id == journal_id


def _in_range(d: date, lo: date | None, hi: date | None) -> bool:
    if lo and d < lo:
        return False
    if hi and d > hi:
        return False
    return True


# ======================================================================
# Document mapping — pure functions, so they're testable without a server.
# ======================================================================
#
# Everything is stored as `model_dump(mode="json")`, i.e. primitives and ISO
# strings. Pydantic coerces them back on read, which keeps the mapping trivial
# and sidesteps the timezone differences between Firestore's native timestamps
# and Python's. ISO strings also sort correctly, since every datetime written is
# UTC.


def recording_to_doc(rec: Recording) -> dict:
    return rec.model_dump(mode="json")


def doc_to_recording(doc: dict) -> Recording:
    return Recording(**doc)


def chunks_to_doc(chunks: list[Chunk]) -> dict:
    """All of a recording's chunks in ONE document.

    A recall query scans every chunk the user owns and Firestore bills per
    document read, so one document per chunk would multiply the cost of every
    question by the chunk count for no benefit. A few hundred chunks of 256
    floats stays far inside the 1 MiB document limit.
    """
    return {"chunks": [c.model_dump(mode="json") for c in chunks]}


def doc_to_chunks(doc: dict | None) -> list[Chunk]:
    if not doc:
        return []
    return [Chunk(**c) for c in doc.get("chunks", [])]


def journal_to_doc(journal: Journal) -> dict:
    return journal.model_dump(mode="json")


def doc_to_journal(doc: dict) -> Journal:
    return Journal(**doc)


def feedback_to_doc(item: Feedback) -> dict:
    return item.model_dump(mode="json")


def doc_to_feedback(doc: dict) -> Feedback:
    return Feedback(**doc)


class FirestoreRepository:
    """The same interface as [Repository], backed by Firestore.

        users/{uid}                                  settings + profile
        users/{uid}/recordings/{rid}                 Recording
        users/{uid}/recordings/{rid}/chunks/all      every chunk, one document
        users/{uid}/journals/{journal_id}            Journal
        users/{uid}/insights/{insight_id}
        users/{uid}/feeds/{yyyy-mm-dd}
        users/{uid}/feedback/{feedback_id}
        emailIndex/{email}                           -> uid
        otpChallenges/{email}                        pending verification

    `emailIndex` and `otpChallenges` sit outside `users/` deliberately: the
    client security rules in `firestore.rules` deny everything outside
    `users/{uid}`, and only the Admin SDK (which bypasses rules) touches them.
    """

    _CHUNKS_DOC = "all"

    def __init__(self, settings: Settings | None = None) -> None:
        self.settings = settings or get_settings()
        self._client = None

    @property
    def db(self):  # pragma: no cover - requires a real project
        if self._client is None:
            from google.cloud import firestore

            self._client = firestore.Client(project=self.settings.gcp_project)
        return self._client

    # -- paths -------------------------------------------------------------
    def _user_doc(self, uid: str):
        return self.db.collection("users").document(uid)

    def _recordings(self, uid: str):
        return self._user_doc(uid).collection("recordings")

    def _journals(self, uid: str):
        return self._user_doc(uid).collection("journals")

    def _chunks_doc(self, uid: str, recording_id: str):
        return self._recordings(uid).document(recording_id).collection("chunks").document(
            self._CHUNKS_DOC
        )

    # -- user settings -----------------------------------------------------
    def get_settings_doc(self, uid: str) -> UserSettings:
        snap = self._user_doc(uid).get()
        data = (snap.to_dict() or {}).get("settings") if snap.exists else None
        return UserSettings(**data) if data else UserSettings()

    def save_settings_doc(self, uid: str, settings: UserSettings) -> UserSettings:
        self._user_doc(uid).set({"settings": settings.model_dump(mode="json")}, merge=True)
        return settings

    # -- profile / identity ------------------------------------------------
    def get_profile(self, uid: str) -> UserProfile | None:
        snap = self._user_doc(uid).get()
        data = (snap.to_dict() or {}).get("profile") if snap.exists else None
        return UserProfile(**data) if data else None

    def save_profile(self, uid: str, profile: UserProfile) -> UserProfile:
        self._user_doc(uid).set({"profile": profile.model_dump(mode="json")}, merge=True)
        return profile

    def uid_for_email(self, email: str) -> str | None:
        snap = self.db.collection("emailIndex").document(normalize_email(email)).get()
        return (snap.to_dict() or {}).get("uid") if snap.exists else None

    def set_email_index(self, email: str, uid: str) -> None:
        self.db.collection("emailIndex").document(normalize_email(email)).set({"uid": uid})

    # -- OTP challenges ----------------------------------------------------
    def get_otp(self, email: str) -> OtpChallenge | None:
        snap = self.db.collection("otpChallenges").document(normalize_email(email)).get()
        return OtpChallenge(**snap.to_dict()) if snap.exists else None

    def save_otp(self, challenge: OtpChallenge) -> OtpChallenge:
        self.db.collection("otpChallenges").document(normalize_email(challenge.email)).set(
            challenge.model_dump(mode="json")
        )
        return challenge

    def delete_otp(self, email: str) -> None:
        self.db.collection("otpChallenges").document(normalize_email(email)).delete()

    # -- journals ----------------------------------------------------------
    def list_journals(self, uid: str) -> list[Journal]:
        items = [doc_to_journal(s.to_dict()) for s in self._journals(uid).stream()]
        # Sorted here rather than in Firestore: a user has at most a couple of
        # dozen journals, so an index buys nothing and case-insensitive order
        # is not something Firestore can express anyway.
        items.sort(key=lambda j: j.name.casefold())
        return items

    def get_journal(self, uid: str, journal_id: str) -> Journal | None:
        snap = self._journals(uid).document(journal_id).get()
        return doc_to_journal(snap.to_dict()) if snap.exists else None

    def save_journal(self, uid: str, journal: Journal) -> Journal:
        self._journals(uid).document(journal.id).set(journal_to_doc(journal))
        return journal

    def delete_journal(self, uid: str, journal_id: str) -> int:
        """See [Repository.delete_journal]. Unfiles, never deletes memories."""
        self._journals(uid).document(journal_id).delete()
        unfiled = 0
        for rec in self.list_recordings(uid, journal_id=journal_id):
            rec.journal_id = ""
            self.update_recording(rec)
            unfiled += 1
        return unfiled

    # -- recordings --------------------------------------------------------
    def add_recording(self, rec: Recording) -> Recording:
        self._recordings(rec.uid).document(rec.id).set(recording_to_doc(rec))
        return rec

    def get_recording(self, uid: str, recording_id: str) -> Recording | None:
        snap = self._recordings(uid).document(recording_id).get()
        return doc_to_recording(snap.to_dict()) if snap.exists else None

    def update_recording(self, rec: Recording) -> Recording:
        self._recordings(rec.uid).document(rec.id).set(recording_to_doc(rec))
        return rec

    def list_recordings(
        self,
        uid: str,
        date_from: date | None = None,
        date_to: date | None = None,
        journal_id: str | None = None,
    ) -> list[Recording]:
        items = [doc_to_recording(s.to_dict()) for s in self._recordings(uid).stream()]
        items = [
            r
            for r in items
            if _in_range(r.event_date, date_from, date_to) and _matches_journal(r, journal_id)
        ]
        # Sorted here rather than in Firestore: the app reads the whole list
        # anyway, so an index buys nothing.
        items.sort(key=lambda r: (r.event_date, r.recorded_at), reverse=True)
        return items

    def delete_recording(self, uid: str, recording_id: str) -> bool:
        doc = self._recordings(uid).document(recording_id)
        if not doc.get().exists:
            return False
        self._chunks_doc(uid, recording_id).delete()
        doc.delete()
        return True

    # -- feedback ----------------------------------------------------------
    def add_feedback(self, item: Feedback) -> Feedback:
        self._user_doc(item.uid).collection("feedback").document(item.id).set(
            feedback_to_doc(item)
        )
        return item

    def list_feedback(self, uid: str) -> list[Feedback]:
        items = [
            doc_to_feedback(s.to_dict())
            for s in self._user_doc(uid).collection("feedback").stream()
        ]
        items.sort(key=lambda f: f.created_at, reverse=True)
        return items

    # -- chunks / vectors --------------------------------------------------
    def save_chunks(self, uid: str, recording_id: str, chunks: list[Chunk]) -> None:
        self._chunks_doc(uid, recording_id).set(chunks_to_doc(chunks))

    def vector_search(
        self,
        uid: str,
        query_vec: list[float],
        top_k: int,
        date_from: date | None = None,
        date_to: date | None = None,
        journal_id: str | None = None,
    ) -> list[SearchHit]:
        # Brute-force cosine over the user's own chunks — same semantics as the
        # in-memory implementation, and no vector index to provision. Only
        # recordings belonging to `uid` are ever read, which is the isolation
        # boundary the RAG pipeline depends on.
        hits: list[SearchHit] = []
        for rec in self.list_recordings(
            uid, date_from=date_from, date_to=date_to, journal_id=journal_id
        ):
            for ch in doc_to_chunks(self._chunks_doc(uid, rec.id).get().to_dict()):
                hits.append(SearchHit(ch, rec, cosine(query_vec, ch.embedding)))
        hits.sort(key=lambda h: h.score, reverse=True)
        return hits[:top_k]

    # -- insights ----------------------------------------------------------
    def save_insight(self, uid: str, insight: Insight) -> Insight:
        self._user_doc(uid).collection("insights").document(insight.id).set(
            insight.model_dump(mode="json")
        )
        return insight

    def get_cached_insight(self, uid: str, insight_id: str) -> Insight | None:
        snap = self._user_doc(uid).collection("insights").document(insight_id).get()
        return Insight(**snap.to_dict()) if snap.exists else None

    # -- memory feed -------------------------------------------------------
    def save_feed(self, uid: str, feed: MemoryFeed) -> MemoryFeed:
        self._user_doc(uid).collection("feeds").document(feed.for_date.isoformat()).set(
            feed.model_dump(mode="json")
        )
        return feed

    def get_feed(self, uid: str, for_date: date) -> MemoryFeed | None:
        snap = self._user_doc(uid).collection("feeds").document(for_date.isoformat()).get()
        return MemoryFeed(**snap.to_dict()) if snap.exists else None

    # ==================================================================
    # Admin plane — top-level collections, outside `users/`.
    #
    # Deliberately not fields on `users/{uid}`: that document is client-writable
    # by its owner (`firestore.rules`), so a `tier` living there could be
    # self-granted from the app. Everything below is covered by the rules file's
    # terminal `allow read, write: if false`, so no rules change is needed.
    # ==================================================================
    def _stats_doc(self, uid: str):  # pragma: no cover - real path
        return self.db.collection("userStats").document(uid)

    def _device_doc(self, install_id: str):  # pragma: no cover - real path
        return self.db.collection("devices").document(install_id)

    def get_user_stats(self, uid: str) -> UserStats | None:  # pragma: no cover - real path
        snap = self._stats_doc(uid).get()
        return UserStats(**snap.to_dict()) if snap.exists else None

    def save_user_stats(self, stats: UserStats) -> UserStats:  # pragma: no cover - real path
        self._stats_doc(stats.uid).set(stats.model_dump(mode="json"))
        return stats

    def ensure_user_stats(self, uid: str) -> tuple[UserStats, bool]:  # pragma: no cover
        existing = self.get_user_stats(uid)
        if existing is not None:
            return existing, False
        created = stats_ops.new_stats(uid)
        self.save_user_stats(created)
        return created, True

    def touch_activity(  # pragma: no cover - real path
        self, uid: str, install_id: str, platform: str, app_version: str
    ) -> tuple[bool, bool]:
        stats, created = self.ensure_user_stats(uid)
        new_day = stats_ops.apply_activity(stats, install_id, platform, app_version)
        self.save_user_stats(stats)
        if install_id:
            self._link_device(uid, install_id, platform, app_version, stats)
        return created, (created or new_day)

    def _link_device(  # pragma: no cover - real path
        self,
        uid: str,
        install_id: str,
        platform: str,
        app_version: str,
        stats: UserStats,
    ) -> None:
        now = datetime.now(timezone.utc)
        doc = self._device_doc(install_id)
        snap = doc.get()
        device = DeviceInfo(**snap.to_dict()) if snap.exists else DeviceInfo(
            install_id=install_id, first_seen_at=now
        )
        device.last_seen_at = now
        if platform:
            device.platform = platform
        if app_version:
            device.app_version = app_version

        account_ref = doc.collection("accounts").document(uid)
        account_snap = account_ref.get()
        account = (
            DeviceAccount(**account_snap.to_dict())
            if account_snap.exists
            else DeviceAccount(uid=uid, install_id=install_id, first_seen_at=now)
        )
        account.last_seen_at = now
        account.email = stats.email
        account.preferred_name = stats.preferred_name
        account_ref.set(account.model_dump(mode="json"))

        # Recount rather than increment: the write is idempotent, so a retry
        # cannot inflate the number that flags a shared device.
        device.account_count = sum(1 for _ in doc.collection("accounts").list_documents())
        doc.set(device.model_dump(mode="json"))

    def record_created(  # pragma: no cover - real path
        self, uid: str, duration_sec: float, recorded_at: datetime
    ) -> UserStats:
        stats, _ = self.ensure_user_stats(uid)
        stats_ops.apply_recording_created(stats, duration_sec, recorded_at)
        return self.save_user_stats(stats)

    def record_deleted(  # pragma: no cover - real path
        self, uid: str, duration_sec: float
    ) -> UserStats | None:
        stats = self.get_user_stats(uid)
        if stats is None:
            return None
        stats_ops.apply_recording_deleted(stats, duration_sec)
        return self.save_user_stats(stats)

    def bump_feedback_count(self, uid: str) -> None:  # pragma: no cover - real path
        stats, _ = self.ensure_user_stats(uid)
        stats.feedback_count += 1
        self.save_user_stats(stats)

    def sync_user_identity(  # pragma: no cover - real path
        self, uid: str, preferred_name: str, email: str, email_verified: bool
    ) -> UserStats:
        stats, _ = self.ensure_user_stats(uid)
        stats_ops.apply_identity(stats, preferred_name, email, email_verified)
        self.save_user_stats(stats)
        for install_id in stats.install_ids:
            ref = self._device_doc(install_id).collection("accounts").document(uid)
            if ref.get().exists:
                ref.set({"email": email, "preferred_name": preferred_name}, merge=True)
        return stats

    def set_tier(  # pragma: no cover - real path
        self, uid: str, tier: UserTier | None, note: str | None, admin_uid: str
    ) -> UserStats | None:
        stats = self.get_user_stats(uid)
        if stats is None:
            return None
        stats_ops.apply_tier(stats, tier, note, admin_uid)
        return self.save_user_stats(stats)

    def recompute_user_stats(self, uid: str) -> UserStats | None:  # pragma: no cover
        stats = self.get_user_stats(uid)
        if stats is None:
            return None
        stats_ops.recompute(stats, self.list_recordings(uid), len(self.list_feedback(uid)))
        return self.save_user_stats(stats)

    def list_user_stats(  # pragma: no cover - real path
        self,
        sort: str = "last_active_at",
        order: str = "desc",
        limit: int = 50,
        cursor: str | None = None,
        tier: str | None = None,
        platform: str | None = None,
        query: str | None = None,
    ) -> tuple[list[UserStats], str | None]:
        from google.cloud import firestore

        from app.models.admin import decode_cursor, encode_cursor

        col = self.db.collection("userStats")
        q = col
        if tier:
            q = q.where("tier", "==", tier)
        if platform:
            q = q.where("platform", "==", platform)

        sort_field = sort if sort in SORTABLE else "last_active_at"
        if query:
            # Firestore requires the first order_by to match the inequality
            # field, so a search *forces* the sort onto the searched field. The
            # router reports the effective sort rather than pretending.
            needle = query.strip().lower()
            q = q.where("email", ">=", needle).where("email", "<", needle + PREFIX_END)
            sort_field = "email"
            q = q.order_by("email")
        else:
            direction = firestore.Query.DESCENDING if order == "desc" else firestore.Query.ASCENDING
            q = q.order_by(sort_field, direction=direction)

        after = decode_cursor(cursor)
        if after:
            snap = col.document(after).get()
            if snap.exists:
                q = q.start_after(snap)

        # One extra row tells us whether a further page exists without a count.
        rows = [UserStats(**s.to_dict()) for s in q.limit(limit + 1).stream()]
        page = rows[:limit]
        next_cursor = encode_cursor(page[-1].uid) if len(rows) > limit and page else None
        return page, next_cursor

    def count_user_stats(  # pragma: no cover - real path
        self, tier: str | None = None, active_since: datetime | None = None
    ) -> int:
        q = self.db.collection("userStats")
        if tier:
            q = q.where("tier", "==", tier)
        if active_since is not None:
            q = q.where("last_active_at", ">=", active_since.isoformat())
        result = q.count().get()
        return int(result[0][0].value)

    def global_summary(self) -> dict:  # pragma: no cover - real path
        """Aggregation queries, not a maintained counter document.

        These bill at roughly one read per 1024 index entries, are always exactly
        fresh, and need no write amplification — where a `globalStats/summary`
        counter would have to stay consistent across create, delete, merge and
        purge, four places to get wrong, to save a handful of reads per load.
        """
        from google.cloud import firestore

        col = self.db.collection("userStats")
        now = datetime.now(timezone.utc)

        def _count(query) -> int:
            return int(query.count().get()[0][0].value)

        def _sum(field: str) -> float:
            return float(col.sum(field).get()[0][0].value or 0)

        # No MAX aggregation exists; one ordered read gets it for the same price.
        top = list(
            col.order_by("max_duration_sec", direction=firestore.Query.DESCENDING).limit(1).stream()
        )
        longest = UserStats(**top[0].to_dict()).max_duration_sec if top else 0.0

        devices = self.db.collection("devices")
        return {
            "users_total": _count(col),
            "users_premium": _count(col.where("tier", "==", UserTier.premium.value)),
            "users_with_email": _count(col.where("email_verified", "==", True)),
            "users_anonymous": _count(col.where("email", "==", "")),
            "recordings_total": int(_sum("recordings_count")),
            "total_duration_sec": round(_sum("total_duration_sec"), 3),
            "max_duration_sec": longest,
            "devices_total": _count(devices),
            "multi_account_devices": _count(devices.where("account_count", ">", 1)),
            "active_1d": self.count_user_stats(active_since=now - timedelta(days=1)),
            "active_7d": self.count_user_stats(active_since=now - timedelta(days=7)),
            "active_30d": self.count_user_stats(active_since=now - timedelta(days=30)),
            "feedback_total": int(_sum("feedback_count")),
            "failed_recordings": len(self.list_failed_recordings(limit=200)),
        }

    # -- devices -----------------------------------------------------------
    def get_device(self, install_id: str) -> DeviceInfo | None:  # pragma: no cover
        snap = self._device_doc(install_id).get()
        return DeviceInfo(**snap.to_dict()) if snap.exists else None

    def list_devices(  # pragma: no cover - real path
        self, limit: int = 50, cursor: str | None = None
    ) -> tuple[list[DeviceInfo], str | None]:
        from google.cloud import firestore

        from app.models.admin import decode_cursor, encode_cursor

        col = self.db.collection("devices")
        q = col.order_by("last_seen_at", direction=firestore.Query.DESCENDING)
        after = decode_cursor(cursor)
        if after:
            snap = col.document(after).get()
            if snap.exists:
                q = q.start_after(snap)
        rows = [DeviceInfo(**s.to_dict()) for s in q.limit(limit + 1).stream()]
        page = rows[:limit]
        next_cursor = encode_cursor(page[-1].install_id) if len(rows) > limit and page else None
        return page, next_cursor

    def list_device_accounts(self, install_id: str) -> list[DeviceAccount]:  # pragma: no cover
        col = self._device_doc(install_id).collection("accounts")
        rows = [DeviceAccount(**s.to_dict()) for s in col.stream()]
        rows.sort(key=lambda a: a.last_seen_at, reverse=True)
        return rows

    def list_devices_for_user(self, uid: str) -> list[DeviceInfo]:  # pragma: no cover
        # From the account's own trail rather than a collection-group scan: the
        # list is already denormalized and capped, so this is O(devices) reads.
        stats = self.get_user_stats(uid)
        if stats is None:
            return []
        devices = [self.get_device(i) for i in stats.install_ids]
        found = [d for d in devices if d is not None]
        found.sort(key=lambda d: d.last_seen_at, reverse=True)
        return found

    # -- daily rollups -----------------------------------------------------
    def bump_daily(  # pragma: no cover - real path
        self, day: date, field: str, amount: float = 1, bucket: str | None = None
    ) -> DailyStats:
        from google.cloud import firestore

        doc = self.db.collection("dailyStats").document(day.isoformat())
        key = f"duration_buckets.{bucket}" if bucket is not None else field
        doc.set(
            {"day": day.isoformat(), key: firestore.Increment(amount)},
            merge=True,
        )
        snap = doc.get()
        return DailyStats(**snap.to_dict()) if snap.exists else DailyStats(day=day)

    def list_daily(self, date_from: date, date_to: date) -> list[DailyStats]:  # pragma: no cover
        col = self.db.collection("dailyStats")
        rows = [
            DailyStats(**s.to_dict())
            for s in col.where("day", ">=", date_from.isoformat())
            .where("day", "<=", date_to.isoformat())
            .stream()
        ]
        rows.sort(key=lambda d: d.day)
        return rows

    # -- feedback triage ---------------------------------------------------
    def list_all_feedback(  # pragma: no cover - real path
        self,
        limit: int = 50,
        cursor: str | None = None,
        kind: str | None = None,
        platform: str | None = None,
    ) -> tuple[list[Feedback], str | None]:
        from google.cloud import firestore

        from app.models.admin import decode_cursor, encode_cursor

        # `Feedback.uid` is denormalized onto the document, so a collection
        # group query needs no join back to the user.
        q = self.db.collection_group("feedback")
        if kind:
            q = q.where("kind", "==", kind)
        if platform:
            q = q.where("platform", "==", platform)
        q = q.order_by("created_at", direction=firestore.Query.DESCENDING)

        after = decode_cursor(cursor)
        rows = [doc_to_feedback(s.to_dict()) for s in q.limit(limit + 1).stream()]
        if after:
            ids = [f.id for f in rows]
            if after in ids:
                rows = rows[ids.index(after) + 1 :]
        page = rows[:limit]
        next_cursor = encode_cursor(page[-1].id) if len(rows) > limit and page else None
        return page, next_cursor

    def get_triage(self, feedback_id: str) -> FeedbackTriage | None:  # pragma: no cover
        snap = self.db.collection("feedbackTriage").document(feedback_id).get()
        return FeedbackTriage(**snap.to_dict()) if snap.exists else None

    def save_triage(self, triage: FeedbackTriage) -> FeedbackTriage:  # pragma: no cover
        self.db.collection("feedbackTriage").document(triage.feedback_id).set(
            triage.model_dump(mode="json")
        )
        return triage

    # -- pipeline health ---------------------------------------------------
    def list_failed_recordings(self, limit: int = 50) -> list[Recording]:  # pragma: no cover
        rows: list[Recording] = []
        for status in (RecordingStatus.failed, RecordingStatus.transcribing):
            rows += [
                doc_to_recording(s.to_dict())
                for s in self.db.collection_group("recordings")
                .where("status", "==", status.value)
                .limit(limit)
                .stream()
            ]
        rows.sort(key=lambda r: r.updated_at, reverse=True)
        return rows[:limit]

    # -- audit -------------------------------------------------------------
    def add_audit(self, entry: AdminAuditEntry) -> AdminAuditEntry:  # pragma: no cover
        self.db.collection("adminAudit").document(entry.id).set(entry.model_dump(mode="json"))
        return entry

    def list_audit(self, limit: int = 100) -> list[AdminAuditEntry]:  # pragma: no cover
        from google.cloud import firestore

        rows = [
            AdminAuditEntry(**s.to_dict())
            for s in self.db.collection("adminAudit")
            .order_by("at", direction=firestore.Query.DESCENDING)
            .limit(limit)
            .stream()
        ]
        return rows

    # -- merge (restore after reinstall) -----------------------------------
    def merge_user(self, src_uid: str, dst_uid: str) -> dict[str, int]:
        """See [Repository.merge_user]. Callers must have proven both sides."""
        if src_uid == dst_uid:
            return {"recordings": 0, "journals": 0, "feedback": 0, "insights": 0, "feeds": 0}

        moved = {"recordings": 0, "journals": 0, "feedback": 0, "insights": 0, "feeds": 0}
        # Journals first: `journal_id` is denormalized onto each recording, so a
        # restored memory has to find the journal it names still there.
        for journal in self.list_journals(src_uid):
            self.save_journal(dst_uid, journal)
            self._journals(src_uid).document(journal.id).delete()
            moved["journals"] += 1

        for rec in self.list_recordings(src_uid):
            chunks = doc_to_chunks(self._chunks_doc(src_uid, rec.id).get().to_dict())
            rec.uid = dst_uid  # denormalized onto the document
            self.add_recording(rec)
            if chunks:
                self.save_chunks(dst_uid, rec.id, chunks)
            self._chunks_doc(src_uid, rec.id).delete()
            self._recordings(src_uid).document(rec.id).delete()
            moved["recordings"] += 1

        for item in self.list_feedback(src_uid):
            src_id = item.id
            item.uid = dst_uid
            self.add_feedback(item)
            self._user_doc(src_uid).collection("feedback").document(src_id).delete()
            moved["feedback"] += 1

        for snap in self._user_doc(src_uid).collection("insights").stream():
            self.save_insight(dst_uid, Insight(**snap.to_dict()))
            snap.reference.delete()
            moved["insights"] += 1

        # Feeds are a derived cache; drop both sides so the next read rebuilds
        # over the combined set rather than serving a stale pre-merge answer.
        for snap in self._user_doc(src_uid).collection("feeds").stream():
            snap.reference.delete()
            moved["feeds"] += 1
        for snap in self._user_doc(dst_uid).collection("feeds").stream():
            snap.reference.delete()

        # Fold the account's history onto the session that now owns it, before
        # the source disappears. `stats.merge_stats` documents why the direction
        # of this call is so easy to get backwards.
        src_stats = self.get_user_stats(src_uid)
        if src_stats is not None:
            dst_stats, _ = self.ensure_user_stats(dst_uid)
            self.save_user_stats(stats_ops.merge_stats(src_stats, dst_stats))
            for install_id in src_stats.install_ids:
                self._device_doc(install_id).collection("accounts").document(src_uid).delete()
            self._stats_doc(src_uid).delete()

        self._user_doc(src_uid).delete()
        return moved

    # -- account deletion (purge) -----------------------------------------
    def delete_user(self, uid: str) -> None:
        profile = self.get_profile(uid)
        for rec in self.list_recordings(uid):
            self._chunks_doc(uid, rec.id).delete()
            self._recordings(uid).document(rec.id).delete()
        for name in ("journals", "feedback", "insights", "feeds"):
            for snap in self._user_doc(uid).collection(name).stream():
                snap.reference.delete()
        if profile and profile.email:
            self.db.collection("emailIndex").document(normalize_email(profile.email)).delete()
        # The install id lives on the stats document and the device link, and
        # nowhere else — removing both is what makes it genuinely deletable.
        stats = self.get_user_stats(uid)
        if stats is not None:
            for install_id in stats.install_ids:
                self._device_doc(install_id).collection("accounts").document(uid).delete()
            self._stats_doc(uid).delete()
        self._user_doc(uid).delete()


_repo_singleton: Repository | FirestoreRepository | None = None


def get_repository() -> Repository | FirestoreRepository:
    """In-memory when mocked, Firestore when a real project is configured.

    Mirrors the mock/real split already used by `storage.py` and `tasks.py`.
    """
    global _repo_singleton
    if _repo_singleton is None:
        settings = get_settings()
        _repo_singleton = (
            Repository(settings) if settings.effective_mock else FirestoreRepository(settings)
        )
    return _repo_singleton


def reset_repository() -> None:
    """Test helper: drop all in-memory state."""
    global _repo_singleton
    _repo_singleton = Repository()


def _reset_repository_choice() -> None:
    """Test helper: forget the singleton so the next call re-picks by settings."""
    global _repo_singleton
    _repo_singleton = None
