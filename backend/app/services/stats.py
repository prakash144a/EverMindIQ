"""Pure transformations on a [UserStats] document.

No I/O here on purpose. Both repository implementations read a document, apply
one of these, and write it back — the in-memory one under its lock, the
Firestore one inside a transaction. Keeping the arithmetic in one place is what
stops the mock and the real path from drifting into different answers, which is
the failure mode that would make the admin console quietly lie.
"""

from __future__ import annotations

from datetime import datetime, timezone

from app.models.recording import Recording
from app.models.user import MAX_TRAIL, UserStats, UserTier


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


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
    stats: UserStats, duration_sec: float, recorded_at: datetime | None = None
) -> UserStats:
    at = recorded_at or _utcnow()
    stats.recordings_count += 1
    stats.total_duration_sec = round(stats.total_duration_sec + duration_sec, 3)
    stats.max_duration_sec = max(stats.max_duration_sec, duration_sec)
    if stats.first_recorded_at is None or at < stats.first_recorded_at:
        stats.first_recorded_at = at
    if stats.last_recording_at is None or at > stats.last_recording_at:
        stats.last_recording_at = at
    return stats


def apply_recording_deleted(stats: UserStats, duration_sec: float) -> UserStats:
    """Reverse a create — except for the maximum, which is a high-water mark.

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
    stats.total_duration_sec = round(sum(r.duration_sec for r in recordings), 3)
    stats.max_duration_sec = max((r.duration_sec for r in recordings), default=0.0)
    stats.feedback_count = feedback_count
    times = sorted(r.recorded_at for r in recordings)
    stats.first_recorded_at = times[0] if times else None
    stats.last_recording_at = times[-1] if times else None
    return stats
