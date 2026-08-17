"""Shapes the admin console sees.

The response models here are the privacy boundary, and they enforce it
structurally rather than by discipline: none of them has a field for a
transcript, a summary, a title, tags, people, places, or a mood. An admin route
returns one of these models, never a `Recording`, so there is no code path that
could serialize a user's memory to an operator.

Those fields are not "harmless metadata" — a title, the people named in a
recording, and the places it mentions are generated *descriptions of the
content*, and are among the most revealing things stored. `test_admin_privacy`
asserts this and will fail if a content field is ever added.
"""

from __future__ import annotations

import base64
import binascii
from datetime import date, datetime, timezone

from pydantic import BaseModel, Field

from app.models.recording import Recording, RecordingStatus
from app.models.user import UserStats, UserTier


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


# Bucket edges in seconds, upper-exclusive; the last bucket is open-ended.
# Frozen at write time: counts are incremented into these buckets as recordings
# are created, so changing the edges does not re-bucket existing data. Bump
# DURATION_BUCKETS_VERSION if they ever change, so old rows are identifiable.
DURATION_BUCKETS: tuple[int, ...] = (15, 30, 60, 120, 300, 600)
DURATION_BUCKETS_VERSION = 1


def bucket_label(duration_sec: float) -> str:
    """The histogram bucket a duration falls in, e.g. "30-60" or "600+"."""
    low = 0
    for edge in DURATION_BUCKETS:
        if duration_sec < edge:
            return f"{low}-{edge}"
        low = edge
    return f"{low}+"


def bucket_labels() -> list[str]:
    """Every bucket label, in order, so a chart has stable empty buckets."""
    labels = []
    low = 0
    for edge in DURATION_BUCKETS:
        labels.append(f"{low}-{edge}")
        low = edge
    labels.append(f"{low}+")
    return labels


# -- pagination ---------------------------------------------------------
#
# Cursor rather than offset: Firestore bills `.offset(n)` as if it had read
# every skipped document, so page 20 of a 50-row list would cost 1000 reads.
# The cursor is the last row's document id, which is unique and therefore makes
# the ordering total — ties at a page boundary can neither skip nor duplicate.


def encode_cursor(doc_id: str) -> str:
    return base64.urlsafe_b64encode(doc_id.encode()).decode().rstrip("=")


def decode_cursor(cursor: str | None) -> str | None:
    """Decode a cursor, treating a malformed one as "start from the beginning".

    Cursors are client-supplied and opaque; a garbled one is a bad request at
    worst, never a reason to 500.
    """
    if not cursor:
        return None
    padded = cursor + "=" * (-len(cursor) % 4)
    try:
        return base64.urlsafe_b64decode(padded.encode()).decode()
    except (binascii.Error, UnicodeDecodeError, ValueError):
        return None


# -- devices ------------------------------------------------------------


class DeviceAccount(BaseModel):
    """One account seen on one device (`devices/{install_id}/accounts/{uid}`)."""

    uid: str
    install_id: str
    email: str = ""
    preferred_name: str = ""
    first_seen_at: datetime = Field(default_factory=_utcnow)
    last_seen_at: datetime = Field(default_factory=_utcnow)


class DeviceInfo(BaseModel):
    """One physical install (`devices/{install_id}`).

    `account_count` is what makes the switch-account feature legible: more than
    one means several people (or several of the user's own accounts) have signed
    in on this device.
    """

    install_id: str
    platform: str = ""
    app_version: str = ""
    first_seen_at: datetime = Field(default_factory=_utcnow)
    last_seen_at: datetime = Field(default_factory=_utcnow)
    account_count: int = 0


class DeviceDetail(BaseModel):
    device: DeviceInfo
    accounts: list[DeviceAccount] = Field(default_factory=list)


# -- daily rollups ------------------------------------------------------


class DailyStats(BaseModel):
    """One document per day, incremented at write time.

    Charting from the raw collections would cost one read per recording per page
    load; this costs one read per day charted, whatever the user count.
    """

    day: date
    # Deliberately separate: `new_users` is fresh installs, `email_signups` is
    # first-time email verifications. Conflating them would make every reinstall
    # and every account switch look like growth.
    new_users: int = 0
    email_signups: int = 0
    recordings: int = 0
    recording_seconds: float = 0.0
    active_users: int = 0
    duration_buckets: dict[str, int] = Field(default_factory=dict)
    buckets_version: int = DURATION_BUCKETS_VERSION


# -- admin views --------------------------------------------------------


class AdminMe(BaseModel):
    uid: str
    email: str = ""
    is_admin: bool = True


class AdminUserRow(BaseModel):
    """A row in the user list. Account administration data only."""

    uid: str
    email: str = ""
    email_verified: bool = False
    preferred_name: str = ""
    tier: UserTier = UserTier.free
    install_id: str = ""
    platform: str = ""
    app_version: str = ""
    recordings_count: int = 0
    total_duration_sec: float = 0.0
    max_duration_sec: float = 0.0
    feedback_count: int = 0
    created_at: datetime
    first_recorded_at: datetime | None = None
    last_recording_at: datetime | None = None
    last_active_at: datetime

    @property
    def is_anonymous(self) -> bool:
        return not self.email

    @classmethod
    def of(cls, stats: UserStats) -> AdminUserRow:
        return cls(
            uid=stats.uid,
            email=stats.email,
            email_verified=stats.email_verified,
            preferred_name=stats.preferred_name,
            tier=stats.tier,
            install_id=stats.install_id,
            platform=stats.platform,
            app_version=stats.app_version,
            recordings_count=stats.recordings_count,
            total_duration_sec=stats.total_duration_sec,
            max_duration_sec=stats.max_duration_sec,
            feedback_count=stats.feedback_count,
            created_at=stats.created_at,
            first_recorded_at=stats.first_recorded_at,
            last_recording_at=stats.last_recording_at,
            last_active_at=stats.last_active_at,
        )


class AdminRecordingRow(BaseModel):
    """Recording metadata with **no content**. See this module's docstring."""

    id: str
    event_date: date
    recorded_at: datetime
    duration_sec: float
    status: RecordingStatus
    language: str = ""
    is_milestone: bool = False

    @classmethod
    def of(cls, rec: Recording) -> AdminRecordingRow:
        # Field by field, never `rec.public_dict()` — that would serialize the
        # transcript, and a future field would be leaked silently.
        return cls(
            id=rec.id,
            event_date=rec.event_date,
            recorded_at=rec.recorded_at,
            duration_sec=rec.duration_sec,
            status=rec.status,
            language=rec.language,
            is_milestone=rec.is_milestone,
        )


class AdminUserDetail(BaseModel):
    user: AdminUserRow
    note: str = ""
    tier_updated_at: datetime | None = None
    tier_updated_by: str = ""
    previous_uids: list[str] = Field(default_factory=list)
    devices: list[DeviceInfo] = Field(default_factory=list)
    recent_recordings: list[AdminRecordingRow] = Field(default_factory=list)


class AdminUserPatch(BaseModel):
    """Only operator-owned fields. Name and email are the user's identity — and
    the email is the account key backing `emailIndex`, so editing it here would
    desynchronize the index."""

    tier: UserTier | None = None
    note: str | None = None


class AdminUserPage(BaseModel):
    items: list[AdminUserRow] = Field(default_factory=list)
    next_cursor: str | None = None
    # The requested sort is ignored when a search is active, because Firestore
    # requires the first order_by to match the inequality field. Reporting it
    # beats letting the console display a sort it did not get.
    sorted_by: str = "last_active_at"


class AdminDevicePage(BaseModel):
    items: list[DeviceInfo] = Field(default_factory=list)
    next_cursor: str | None = None


class AdminCount(BaseModel):
    value: int


class AdminOverview(BaseModel):
    users_total: int = 0
    users_premium: int = 0
    users_with_email: int = 0
    users_anonymous: int = 0
    recordings_total: int = 0
    total_duration_sec: float = 0.0
    max_duration_sec: float = 0.0
    devices_total: int = 0
    multi_account_devices: int = 0
    active_1d: int = 0
    active_7d: int = 0
    active_30d: int = 0
    feedback_total: int = 0
    failed_recordings: int = 0


class AdminFeedbackRow(BaseModel):
    id: str
    uid: str
    kind: str
    # The one deliberate content exception: the user wrote this *to* the
    # operator, in a "report a problem" box, expecting a human to read it.
    message: str
    diagnostics: str = ""
    app_version: str = ""
    platform: str = ""
    created_at: datetime
    status: str = "new"
    admin_note: str = ""


class AdminFeedbackPage(BaseModel):
    items: list[AdminFeedbackRow] = Field(default_factory=list)
    next_cursor: str | None = None


class AdminFeedbackPatch(BaseModel):
    status: str | None = None
    admin_note: str | None = None


class FeedbackTriage(BaseModel):
    """Admin-owned triage state, kept out of `users/{uid}/feedback/{id}` because
    that document is client-writable — a user could otherwise reopen their own
    ticket."""

    feedback_id: str
    status: str = "new"
    admin_note: str = ""
    updated_at: datetime = Field(default_factory=_utcnow)
    updated_by: str = ""


class TimeSeriesPoint(BaseModel):
    day: date
    value: float


class AdminTimeSeries(BaseModel):
    metric: str
    points: list[TimeSeriesPoint] = Field(default_factory=list)


class HistogramBucket(BaseModel):
    label: str
    count: int


class AdminHistogram(BaseModel):
    buckets: list[HistogramBucket] = Field(default_factory=list)
    total: int = 0
    # Interpolated from bucket counts, not exact — named so nobody mistakes them
    # for true percentiles.
    p50_approx: float = 0.0
    p90_approx: float = 0.0
    max_duration_sec: float = 0.0


class AdminAuditEntry(BaseModel):
    id: str
    at: datetime = Field(default_factory=_utcnow)
    admin_uid: str
    admin_email: str = ""
    action: str
    target: str = ""
    detail: str = ""


class AdminAuditPage(BaseModel):
    items: list[AdminAuditEntry] = Field(default_factory=list)
