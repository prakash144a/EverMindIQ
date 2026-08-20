"""What a tier actually buys.

Until typed memories there was nothing here to write: `tier` was an admin-set
label with an audit trail that changed nothing for the user. This is the first
place a tier changes behaviour, so the mapping lives in one module rather than
being inlined at the call site where the next entitlement would have to copy it.

The tier is read from `userStats/{uid}`, which is deliberately *not* the
client-writable `users/{uid}` document (see `models/user.UserStats`) — so an
entitlement cannot be self-granted from the app.
"""

from __future__ import annotations

from app.core.config import get_settings
from app.models.user import UserTier
from app.services.stats import voice_recordings_in_month


def max_text_chars(tier: UserTier) -> int:
    """The longest typed memory this tier may save."""
    settings = get_settings()
    if tier is UserTier.premium:
        return settings.text_max_chars_premium
    return settings.text_max_chars_free


def max_journals(tier: UserTier) -> int:
    """How many journals this tier may keep."""
    settings = get_settings()
    if tier is UserTier.premium:
        return settings.journals_max_premium
    return settings.journals_max_free


def max_recordings_per_month(tier: UserTier) -> int:
    """How many voice memories this tier may create in a calendar month.

    Voice only. A typed memory costs us nothing to transcribe, so metering it
    would buy nothing and would make the free tier unusable as a notebook.
    """
    settings = get_settings()
    if tier is UserTier.premium:
        return settings.recordings_per_month_premium
    return settings.recordings_per_month_free


def max_recording_seconds(tier: UserTier) -> int:
    """How long a single recording may be, in seconds."""
    settings = get_settings()
    if tier is UserTier.premium:
        return settings.recording_max_seconds_premium
    return settings.recording_max_seconds_free


def max_voice_session_seconds(tier: UserTier) -> int:
    """How long one spoken recall conversation may last, in seconds."""
    settings = get_settings()
    if tier is UserTier.premium:
        return settings.voice_session_max_seconds_premium
    return settings.voice_session_max_seconds_free


def tier_for(repo, uid: str) -> UserTier:
    """The caller's tier, free when we have never seen them.

    Free on a missing stats document is the restrictive direction, which is the
    correct way for an entitlement lookup to fail.
    """
    stats = repo.get_user_stats(uid)
    return stats.tier if stats else UserTier.free


def tier_and_voice_usage(repo, uid: str) -> tuple[UserTier, int]:
    """The caller's tier *and* how many voice memories they have made this month.

    One read for both, because every caller that needs the quota also needs the
    tier to know what the quota is, and `userStats` is one document.
    """
    stats = repo.get_user_stats(uid)
    if stats is None:
        return UserTier.free, 0
    return stats.tier, voice_recordings_in_month(stats)
