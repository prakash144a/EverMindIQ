"""Pure transformations on a [UserStats] document.

No I/O here on purpose. Both repository implementations read a document, apply
one of these, and write it back — the in-memory one under its lock, the
Firestore one inside a transaction. Keeping the arithmetic in one place is what
stops the mock and the real path from drifting into different answers, which is
the failure mode that would make the admin console quietly lie.
"""

from __future__ import annotations

from datetime import date, datetime, timezone

from app.models.recording import Recording, RecordingSource
from app.models.user import MAX_TRAIL, UserStats, UserTier


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


def month_key(at: datetime | None = None) -> str:
    """The calendar month a usage counter belongs to, as "YYYY-MM", in UTC.

    UTC rather than the user's local month, because the server has no reliable
    idea what the user's timezone is and a quota that rolls over at a different
    instant per request is a quota nobody can reason about.
    """
    return (at or _utcnow()).strftime("%Y-%m")


def voice_recordings_in_month(stats: UserStats, at: datetime | None = None) -> int:
    """How many voice memories this account has made in the month containing `at`.

    A stored counter from an earlier month reads as zero rather than being reset
    here: this is the read path, and rewriting the document on a read would turn
    every profile fetch into a write.
    """
    if stats.usage_month != month_key(at):
        return 0
    return stats.voice_recordings_this_month


def month_resets_on(at: datetime | None = None) -> date:
    """The first day of the month after the one containing `at`.

    What the app shows as "resets on"; computed here so the API and any future
    caller agree on the date rather than each doing its own month arithmetic.
    """
    day = (at or _utcnow()).date()
    return date(day.year + 1, 1, 1) if day.month == 12 else date(day.year, day.month + 1, 1)


def new_stats(uid: str, now: datetime | None = None) -> UserStats:
    at = now or _utcnow()
    return UserStats(
        uid=uid,
        created_at=at,
        signup_day=at.date(),
        last_active_at=at,
        last_active_day=at.date(),
    )


def apply_activity(
    stats: UserStats,
    install_id: str,
    platform: str,
    app_version: str,
    now: datetime | None = None,
) -> bool:
    """Record a sign of life. Returns True if this is the user's first activity today.

    The caller uses that return to increment the daily active-user counter
    exactly once per user per day — the check is against the *stored* day, not
    an in-process cache, so it stays exact across however many instances are
    running.
    """
    at = now or _utcnow()
    is_new_day = stats.last_active_day != at.date()
    stats.last_active_at = at
    stats.last_active_day = at.date()
    if install_id:
        stats.touch_trail(install_id)
    if platform:
        stats.platform = platform
    if app_version:
        stats.app_version = app_version
    return is_new_day


def apply_recording_created(
    stats: UserStats,
    duration_sec: float,
    recorded_at: datetime | None = None,
    *,
    is_voice: bool = True,
) -> UserStats:
    at = recorded_at or _utcnow()
    stats.recordings_count += 1
    if is_voice:
        # Metered against the month this ran in, never against `recorded_at`: a
        # back-dated memory is created now and costs now, so letting the event
        # date pick the bucket would hand out a fresh quota per past month.
        _bump_voice_month(stats)
    stats.total_duration_sec = round(stats.total_duration_sec + duration_sec, 3)
    stats.max_duration_sec = max(stats.max_duration_sec, duration_sec)
    if stats.first_recorded_at is None or at < stats.first_recorded_at:
        stats.first_recorded_at = at
    if stats.last_recording_at is None or at > stats.last_recording_at:
        stats.last_recording_at = at
    return stats


def _bump_voice_month(stats: UserStats, at: datetime | None = None) -> None:
    """Count one voice memory against the current month, rolling over if needed."""
    key = month_key(at)
    if stats.usage_month != key:
        stats.usage_month = key
        stats.voice_recordings_this_month = 0
    stats.voice_recordings_this_month += 1


def apply_recording_deleted(stats: UserStats, duration_sec: float) -> UserStats:
    """Reverse a create — except for the maximum, which is a high-water mark.

    The monthly voice meter is deliberately *not* reversed either. It measures
    what the account has spent this month, and the transcription was already paid
    for by the time anyone can delete the memory — refunding the slot would make
    the quota bypassable by recording, keeping the transcript, and deleting.

    A max cannot be decremented without rescanning every remaining recording,
    which is exactly the per-delete O(N) cost this design exists to avoid. So
    `max_duration_sec` means "the longest recording this account has ever made",
    and `total_duration_sec` can legitimately end up below it. `recompute` is
    the escape hatch when an exact figure is wanted.
    """
    stats.recordings_count = max(0, stats.recordings_count - 1)
    stats.total_duration_sec = max(0.0, round(stats.total_duration_sec - duration_sec, 3))
    return stats


def apply_identity(
    stats: UserStats, preferred_name: str, email: str, email_verified: bool
) -> UserStats:
    stats.preferred_name = preferred_name
    stats.preferred_name_lower = preferred_name.strip().lower()
    stats.email = email
    stats.email_verified = email_verified
    return stats


def apply_tier(
    stats: UserStats,
    tier: UserTier | None,
    note: str | None,
    admin_uid: str,
    now: datetime | None = None,
) -> UserStats:
    if tier is not None and tier != stats.tier:
        stats.tier = tier
        stats.tier_updated_at = now or _utcnow()
        stats.tier_updated_by = admin_uid
    if note is not None:
        stats.note = note
    return stats


def _merge_voice_month(src: UserStats, dst: UserStats) -> None:
    """Fold one account's monthly meter into another's, matching `merge_stats`.

    Only the current month's counters add up; a stale one on either side reads as
    zero. Restoring an account must not hand back a quota, and must not charge
    the caller for a month they have already left behind.
    """
    key = month_key()
    used = voice_recordings_in_month(src, None) + voice_recordings_in_month(dst, None)
    dst.usage_month = key
    dst.voice_recordings_this_month = used


def merge_stats(src: UserStats, dst: UserStats) -> UserStats:
    """Fold `src` into `dst`, matching `Repository.merge_user`'s direction.

    Read the direction carefully. The only caller is the OTP restore path, which
    calls ``merge_user(account_uid, session_uid)`` — so **src is the long-lived
    real account** and **dst is the fresh anonymous session** the caller is
    currently holding. Everything that represents account history therefore has
    to be taken from `src`:

    * `created_at` takes the earlier of the two, or every sign-in would reset
      the account's signup date to today.
    * `tier` upgrades and never downgrades, or every sign-in would silently
      revoke a premium account.

    Getting either backwards is invisible in normal use and corrupts the data
    permanently, which is why it is spelled out here rather than inlined.
    """
    dst.recordings_count += src.recordings_count
    _merge_voice_month(src, dst)
    dst.total_duration_sec = round(dst.total_duration_sec + src.total_duration_sec, 3)
    dst.max_duration_sec = max(dst.max_duration_sec, src.max_duration_sec)
    dst.feedback_count += src.feedback_count

    dst.created_at = min(dst.created_at, src.created_at)
    dst.signup_day = dst.created_at.date()

    if src.first_recorded_at and (
        dst.first_recorded_at is None or src.first_recorded_at < dst.first_recorded_at
    ):
        dst.first_recorded_at = src.first_recorded_at
    if src.last_recording_at and (
        dst.last_recording_at is None or src.last_recording_at > dst.last_recording_at
    ):
        dst.last_recording_at = src.last_recording_at

    if src.tier == UserTier.premium:
        dst.tier = UserTier.premium
        dst.tier_updated_at = dst.tier_updated_at or src.tier_updated_at
        dst.tier_updated_by = dst.tier_updated_by or src.tier_updated_by
    if src.note and not dst.note:
        dst.note = src.note

    # Lineage: the old uid is about to be deleted, so this is the only record
    # that it ever existed.
    trail = [*dst.previous_uids, *src.previous_uids, src.uid]
    seen: list[str] = []
    for uid in trail:
        if uid and uid != dst.uid and uid not in seen:
            seen.append(uid)
    dst.previous_uids = seen[-MAX_TRAIL:]

    # The device the caller is holding right now stays current; the account's
    # older devices are kept behind it.
    devices = [*src.install_ids, *dst.install_ids]
    merged: list[str] = []
    for device in devices:
        if device and device not in merged:
            merged.append(device)
    dst.install_ids = merged[-MAX_TRAIL:]
    if dst.install_id:
        dst.touch_trail(dst.install_id)
    return dst


def recompute(stats: UserStats, recordings: list[Recording], feedback_count: int) -> UserStats:
    """Rebuild the derived counters from the source of truth.

    Unlike the incremental path this *does* recompute the maximum, so it is also
    the way to correct a high-water mark left behind by deletions.
    """
    stats.recordings_count = len(recordings)
    # Rebuilt from `created_at`, the same clock the incremental path meters
    # against — see `apply_recording_created`.
    key = month_key()
    stats.usage_month = key
    stats.voice_recordings_this_month = sum(
        1
        for r in recordings
        if r.source is not RecordingSource.text and month_key(r.created_at) == key
    )
    stats.total_duration_sec = round(sum(r.duration_sec for r in recordings), 3)
    stats.max_duration_sec = max((r.duration_sec for r in recordings), default=0.0)
    stats.feedback_count = feedback_count
    times = sorted(r.recorded_at for r in recordings)
    stats.first_recorded_at = times[0] if times else None
    stats.last_recording_at = times[-1] if times else None
    return stats
