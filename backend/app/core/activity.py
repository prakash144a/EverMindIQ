"""Record that an account is alive, without a database write per request.

Three headers ride along on every authenticated call (see the Flutter client's
`ApiClient._headers`): the install id, the platform, and the app version. A
naive implementation would write them on every request — and this app polls
`GET /recordings` up to 24 times while a single transcript is in flight, so that
would be a write amplification bug of exactly the kind `docs/milestones.md`
Phase 4 already tracks two of.

Instead an in-process cache suppresses the repeat: a given uid is written at
most once per day per instance, per distinct device fingerprint. Cloud Run
scales from zero to ten instances, so the cache is per-instance and imperfect;
the worst case is a handful of redundant writes per user per day, which is the
right trade. The daily active-user counter stays *exact* regardless, because the
repository decides whether to increment it by comparing the **stored** day, not
this cache.
"""

from __future__ import annotations

import logging
from datetime import datetime, timezone

from fastapi import Depends, Header

from app.core.security import CurrentUser, get_current_user
from app.services.firestore import get_repository

log = logging.getLogger(__name__)

# uid -> (day-iso, install_id, platform, app_version)
_seen: dict[str, tuple[str, str, str, str]] = {}

# A long-lived instance would otherwise grow this without bound. Clearing
# wholesale rather than evicting one entry costs a day's worth of redundant
# writes at most, and keeps the structure a plain dict.
_MAX_SEEN = 10_000


def reset_activity_cache() -> None:
    """Test helper: forget who has been seen."""
    _seen.clear()


async def track_activity(
    user: CurrentUser = Depends(get_current_user),
    x_install_id: str | None = Header(default=None),
    x_platform: str | None = Header(default=None),
    x_app_version: str | None = Header(default=None),
) -> CurrentUser:
    """Dependency: note that `user` is active, cheaply.

    Never raises. Activity tracking is bookkeeping — a failure here must not
    turn a working request into an error for the user, so it is logged and
    swallowed, matching the house pattern in `recordings.py::_delete_audio_quietly`.
    """
    now = datetime.now(timezone.utc)
    install_id = (x_install_id or "").strip()[:128]
    platform = (x_platform or "").strip()[:64]
    app_version = (x_app_version or "").strip()[:64]

    fingerprint = (now.date().isoformat(), install_id, platform, app_version)
    if _seen.get(user.uid) == fingerprint:
        return user

    try:
        repo = get_repository()
        created, first_today = repo.touch_activity(user.uid, install_id, platform, app_version)
        if created:
            repo.bump_daily(now.date(), "new_users")
        if first_today:
            repo.bump_daily(now.date(), "active_users")
    except Exception:  # pragma: no cover - bookkeeping must never fail a request
        log.exception("failed to record activity for uid %s", user.uid)
        return user

    if len(_seen) >= _MAX_SEEN:
        _seen.clear()
    _seen[user.uid] = fingerprint
    return user
