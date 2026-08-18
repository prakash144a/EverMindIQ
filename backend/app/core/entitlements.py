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


def tier_for(repo, uid: str) -> UserTier:
    """The caller's tier, free when we have never seen them.

    Free on a missing stats document is the restrictive direction, which is the
    correct way for an entitlement lookup to fail.
    """
    stats = repo.get_user_stats(uid)
    return stats.tier if stats else UserTier.free
