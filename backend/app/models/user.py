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

# The `summary_language` value that means "whatever language the memory is in".
SUMMARY_LANGUAGE_MEMORY = "memory"
_SUMMARY_LANGUAGE_RE = r"^(memory|[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*)$"


class UserSettings(BaseModel):
    on_this_day_enabled: bool = True
    slideshow_interval_sec: int = 6
    notifications_enabled: bool = True
    # "auto" = answer in the language of the question; or an ISO code like "en".
    answer_language: str = "auto"
    # Language a memory's title and summary are written in. "memory" = the
    # language the memory itself is in; or a BCP-47 code like "en". Separate from
    # `answer_language` because that one's "auto" means "match my question", and
    # a saved memory has no question to match. Pattern-checked, not free text:
    # the value is placed in the enrichment prompt.
    summary_language: str = Field(default=SUMMARY_LANGUAGE_MEMORY, pattern=_SUMMARY_LANGUAGE_RE)
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

    recordings_count: int = 0

    # The monthly voice quota's meter. Two fields rather than a map keyed by
    # month: a quota nobody can look back at does not need a history, and one
    # counter beside the month it belongs to makes the roll-over a comparison
    # instead of a cleanup job. `usage_month` is "YYYY-MM" in UTC; a value that
    # is not the current month means the count is stale and reads as zero (see
    # `services.stats.voice_recordings_in_month`).
    usage_month: str = ""
    voice_recordings_this_month: int = 0

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
    # Which installation asked. The device that asks must be the device that
    # answers, or a code glimpsed in someone else's inbox could be redeemed
    # elsewhere. Bound to the install id rather than to an account, because at
    # this point in the flow there is no account and no session yet.
    requester_install_id: str = ""

    def is_expired(self, now: datetime | None = None) -> bool:
        return (now or _utcnow()) >= self.expires_at


def device_label(platform: str) -> str:
    """How to name a device to the person being signed out of it.

    Everything the server knows is the platform string, so this stays vague on
    purpose: "an Android phone" is honest, "your Samsung Galaxy" would not be.
    """
    return {
        "android": "an Android phone",
        "ios": "an iPhone",
        "macos": "a Mac",
        "windows": "a Windows PC",
        "linux": "a Linux computer",
        "web": "a web browser",
    }.get(platform.strip().lower(), "another device")


# The two kinds of place an account can be open at once. An account holds one
# session in each, and they never contend: signing in on a laptop's browser is
# not a reason to sign a phone out, because the phone is not where the browser
# is. Within a surface the old rule stands unchanged — one phone, one browser —
# which is what keeps a shared device from quietly staying signed in.
SURFACE_MOBILE = "mobile"
SURFACE_WEB = "web"
SURFACES = (SURFACE_MOBILE, SURFACE_WEB)


def surface_for(platform: str) -> str:
    """Which slot a device signs into, from the platform it reports.

    Everything that is not a browser is "mobile", including the desktop builds:
    the distinction that matters is *the browser*, which is the one client that
    can be opened alongside the phone someone is carrying. A platform we have
    never heard of is treated as mobile rather than given a slot of its own, so
    an unrecognised client can never mint itself extra sessions.
    """
    return SURFACE_WEB if platform.strip().lower() == "web" else SURFACE_MOBILE


class DeviceSession(BaseModel):
    """One device's hold on an account, within one surface.

    An account has at most one per surface — one mobile, one browser — so the
    phone in someone's pocket and the tab on their laptop can both be open, and
    a memory recorded in either shows up in the other. Signing in on a second
    phone still ends the first phone's session, and signing out still frees that
    device for whoever picks it up next: these are private memories on devices
    that get shared, and the rule only relaxes *across* surfaces, never within
    one.
    """

    session_id: str
    install_id: str = ""
    platform: str = ""
    app_version: str = ""
    signed_in_at: datetime = Field(default_factory=_utcnow)

    @property
    def label(self) -> str:
        return device_label(self.platform)

    @property
    def surface(self) -> str:
        return surface_for(self.platform)


class LoginTicket(BaseModel):
    """A correct code, spent but not yet exchanged for a session.

    Login is two steps because of what happens between them: a second device has
    to be able to ask "sign the other one out?" *before* it takes over, and by
    then the code is already burned. This is what it holds instead — single use,
    short lived, and only redeemable from the device that earned it.
    """

    ticket: str
    uid: str
    email: str
    expires_at: datetime
    created_at: datetime = Field(default_factory=_utcnow)
    # The device that verified, carried through so the session it opens is
    # labelled with the phone the person is actually holding.
    install_id: str = ""
    platform: str = ""
    app_version: str = ""
    # A brand-new account, as opposed to signing back in to an existing one.
    is_new_account: bool = False

    def is_expired(self, now: datetime | None = None) -> bool:
        return (now or _utcnow()) >= self.expires_at


class ProfileView(BaseModel):
    """What ``GET /profile`` returns.

    Carries the caller's entitlements as well as their identity. The app needs
    the typed-memory cap before the user starts typing, and folding it in here
    reuses a call the app already makes on launch rather than adding a second
    round trip for one integer. Every limit the app has to honour before it calls
    an API now rides along for the same reason.
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

    # The monthly voice quota, and how much of it is gone. Both are sent because
    # the app has to be able to stop someone *before* they record: discovering
    # the quota from a 403 after the audio is already uploaded wastes their words.
    recordings_per_month: int = 0
    recordings_used_this_month: int = 0
    recordings_month_resets_on: date | None = None

    # Seconds. The recorder stops itself at `recording_max_sec` and voice mode
    # counts down `voice_session_max_sec`, so both have to be known up front.
    recording_max_sec: int = 0
    voice_session_max_sec: int = 0

    # Days after saving that a memory's title and words can still be edited. The
    # app disables those controls itself once this has passed.
    edit_window_days: int = 0

    @property
    def recordings_left_this_month(self) -> int:
        return max(0, self.recordings_per_month - self.recordings_used_this_month)

    @classmethod
    def of(
        cls,
        profile: UserProfile | None,
        tier: UserTier = UserTier.free,
        recordings_used_this_month: int = 0,
    ) -> ProfileView:
        # Imported here rather than at module scope: `core.entitlements` reads
        # settings and imports this module for `UserTier`.
        from app.core.entitlements import (
            edit_window_days,
            max_journals,
            max_recording_seconds,
            max_recordings_per_month,
            max_text_chars,
            max_voice_session_seconds,
        )
        from app.services.stats import month_resets_on

        limits = {
            "tier": tier,
            "text_max_chars": max_text_chars(tier),
            "journals_max": max_journals(tier),
            "recordings_per_month": max_recordings_per_month(tier),
            "recordings_used_this_month": recordings_used_this_month,
            "recordings_month_resets_on": month_resets_on(),
            "recording_max_sec": max_recording_seconds(tier),
            "voice_session_max_sec": max_voice_session_seconds(tier),
            "edit_window_days": edit_window_days(),
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
    "SUMMARY_LANGUAGE_MEMORY",
    "DeviceSession",
    "LoginTicket",
    "OtpChallenge",
    "ProfileView",
    "ThemeMode",
    "UserProfile",
    "UserSettings",
    "UserStats",
    "UserTier",
    "device_label",
    "is_email",
    "normalize_email",
]
