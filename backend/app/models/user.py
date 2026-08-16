from __future__ import annotations

import re
from datetime import datetime, timezone

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


class UserSettings(BaseModel):
    on_this_day_enabled: bool = True
    slideshow_interval_sec: int = 6
    notifications_enabled: bool = True
    # "auto" = answer in the language of the question; or an ISO code like "en".
    answer_language: str = "auto"
    retention_days: int = 0  # 0 = keep forever


class UserProfile(BaseModel):
    """Who the user is, once they've verified an email.

    Kept separate from [UserSettings] because ``PUT /settings`` replaces the whole
    settings document — a profile field living there would be wiped by any
    settings toggle.
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
    """What ``GET /profile`` returns."""

    preferred_name: str = ""
    email: str = ""
    email_verified: bool = False
    signup_prompt_dismissed: bool = False
    has_profile: bool = False

    @classmethod
    def of(cls, profile: UserProfile | None) -> ProfileView:
        if profile is None:
            return cls()
        return cls(
            preferred_name=profile.preferred_name,
            email=profile.email,
            email_verified=profile.email_verified,
            signup_prompt_dismissed=profile.signup_prompt_dismissed,
            has_profile=profile.has_profile,
        )


__all__ = [
    "OtpChallenge",
    "ProfileView",
    "UserProfile",
    "UserSettings",
    "is_email",
    "normalize_email",
]
