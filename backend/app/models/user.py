from __future__ import annotations

import re
from datetime import date, datetime, timezone
from enum import Enum

from typing import Literal

from pydantic import BaseModel, Field

# Deliberately permissive, and not pydantic's EmailStr — that needs the
# email-validator package, which isn't a dependency. Real validation is the OTP:
# an address that can't receive the code can't complete signup.
_EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s.]+(\.[^@\s.]+)+$")


def is_email(value: str) -> bool:
    return bool(_EMAIL_RE.match(value.strip()))


def normalize_email(value: str) -> str:
    """Lowercase + trim, so the email index has exactly one key per address."""
    return value.strip().lower()


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


# A Literal rather than an Enum: it serialises as a plain string through the
# repository's ``model_dump(mode="json")`` with no extra machinery, and an
# unknown value is rejected with a 422 instead of being stored.
ThemeMode = Literal["system", "light", "dark"]


class UserSettings(BaseModel):
    on_this_day_enabled: bool = True
    slideshow_interval_sec: int = 6
    notifications_enabled: bool = True
    # "auto" = answer in the language of the question; or an ISO code like "en".
    answer_language: str = "auto"
    retention_days: int = 0  # 0 = keep forever
    # Which theme the app paints in; "system" follows the OS. Stored server-side
    # so a second device inherits the choice.
    theme_mode: ThemeMode = "system"


class UserProfile(BaseModel):
    """Who the user is, once they've verified an email.

    Kept separate from [UserSettings] because ``PUT /settings`` owns that whole
    document — a profile field living there would be wiped by any settings
    toggle. (The PUT now merges over omitted keys, but a stale value that *is*
    present is still written through, so the separation still earns its keep.)
    """

    preferred_name: str = ""
    email: str = ""
    email_verified: bool = False
    # Lets the app stop re-asking after the user has said "not now". Stored on the
    # server rather than on the device so a reinstall (a fresh uid, hence a fresh
    # profile) deliberately asks again — which is what offers the restore path.
    signup_prompt_dismissed: bool = False
    created_at: datetime = Field(default_factory=_utcnow)
    updated_at: datetime = Field(default_factory=_utcnow)

    @property
    def has_profile(self) -> bool:
        return bool(self.email and self.email_verified)


class UserTier(str, Enum):
    free = "free"
    premium = "premium"


# Cap the device/lineage trails. They exist to make a history legible in the
# admin console, not to be a complete audit trail, and an unbounded list on a
# hot document is a slow leak.
MAX_TRAIL = 20


class UserStats(BaseModel):
    """Operator-facing view of one account: counters, tier, device, lineage.

    Lives in the top-level ``userStats`` collection, deliberately NOT as a field
    on ``users/{uid}``. That document is client-writable by its owner (see
    ``firestore.rules``), so a ``tier`` stored there could be self-granted from
    the app. Everything here is written only by the server.
    """

    uid: str
    tier: UserTier = UserTier.free
    tier_updated_at: datetime | None = None
    tier_updated_by: str = ""
    note: str = ""

    # Denormalized from the profile so listing users costs one read per row
    # instead of a second lookup each.
    preferred_name: str = ""
    preferred_name_lower: str = ""
    email: str = ""
    email_verified: bool = False

    install_id: str = ""
    install_ids: list[str] = Field(default_factory=list)
    platform: str = ""
    app_version: str = ""

    # Signing in to an existing account merges it onto the caller's *current*
    # uid and deletes the old one, so uids churn. Without this trail an
    # account's history would vanish every time someone signed back in.
    previous_uids: list[str] = Field(default_factory=list)

    recordings_count: int = 0
    total_duration_sec: float = 0.0
    # High-water mark: the longest recording ever made, never decremented on
    # delete (you cannot decrement a max without rescanning). That is also the
    # more useful statistic for "how long do people expect to record for".
    max_duration_sec: float = 0.0
    feedback_count: int = 0

    created_at: datetime = Field(default_factory=_utcnow)
    signup_day: date = Field(default_factory=lambda: _utcnow().date())
    first_recorded_at: datetime | None = None
    last_recording_at: datetime | None = None
    last_active_at: datetime = Field(default_factory=_utcnow)
    last_active_day: date = Field(default_factory=lambda: _utcnow().date())

    # Lets a future backfill find documents written by an older shape.
    stats_version: int = 1

    def touch_trail(self, install_id: str) -> None:
        """Record a device against this account, newest last, without duplicates."""
        if not install_id:
            return
        self.install_id = install_id
        if install_id in self.install_ids:
            self.install_ids.remove(install_id)
        self.install_ids.append(install_id)
        del self.install_ids[:-MAX_TRAIL]


class OtpChallenge(BaseModel):
    """A pending email verification.

    ``code_sha256`` is a hash — the plaintext code exists only in the email and in
    the caller's head, so a leaked datastore can't be replayed.
    """

    email: str
    code_sha256: str
    expires_at: datetime
    sent_at: datetime = Field(default_factory=_utcnow)
    attempts: int = 0
    # Who asked. Used to spot the reinstall case: if this differs from the uid
    # already registered to the email, the caller is restoring, not signing up.
    requester_uid: str = ""

    def is_expired(self, now: datetime | None = None) -> bool:
        return (now or _utcnow()) >= self.expires_at


class ProfileView(BaseModel):
    """What ``GET /profile`` returns.

    Carries the caller's entitlements as well as their identity. The app needs
    the typed-memory cap before the user starts typing, and folding it in here
    reuses a call the app already makes on launch rather than adding a second
    round trip for one integer.
    """

    preferred_name: str = ""
    email: str = ""
    email_verified: bool = False
    signup_prompt_dismissed: bool = False
    has_profile: bool = False

    # Entitlements. Read-only to the client — tier lives in `userStats`, which no
    # client can write.
    tier: UserTier = UserTier.free
    text_max_chars: int = 0
    journals_max: int = 0

    @classmethod
    def of(cls, profile: UserProfile | None, tier: UserTier = UserTier.free) -> ProfileView:
        # Imported here rather than at module scope: `core.entitlements` reads
        # settings and imports this module for `UserTier`.
        from app.core.entitlements import max_journals, max_text_chars

        limits = {
            "tier": tier,
            "text_max_chars": max_text_chars(tier),
            "journals_max": max_journals(tier),
        }
        if profile is None:
            return cls(**limits)
        return cls(
            preferred_name=profile.preferred_name,
            email=profile.email,
            email_verified=profile.email_verified,
            signup_prompt_dismissed=profile.signup_prompt_dismissed,
            has_profile=profile.has_profile,
            **limits,
        )


__all__ = [
    "MAX_TRAIL",
    "OtpChallenge",
    "ProfileView",
    "ThemeMode",
    "UserProfile",
    "UserSettings",
    "UserStats",
    "UserTier",
    "is_email",
    "normalize_email",
]
