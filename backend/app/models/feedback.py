from __future__ import annotations

from datetime import datetime, timezone
from enum import Enum

from pydantic import BaseModel, Field

# Diagnostics are pasted from the app's error log; cap them so one report can't
# store an unbounded blob.
MAX_DIAGNOSTICS = 20_000


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


class FeedbackKind(str, Enum):
    problem = "problem"
    idea = "idea"
    other = "other"


class FeedbackCreate(BaseModel):
    """What the app sends when the user reports something."""

    kind: FeedbackKind = FeedbackKind.problem
    message: str = Field(..., min_length=1, max_length=5000)
    # Captured error text/stack the user chose to attach. Optional by design —
    # a report must never be blocked on having diagnostics.
    diagnostics: str = Field(default="", max_length=MAX_DIAGNOSTICS)
    app_version: str = Field(default="", max_length=64)
    platform: str = Field(default="", max_length=64)


class Feedback(BaseModel):
    id: str
    uid: str
    kind: FeedbackKind
    message: str
    diagnostics: str = ""
    app_version: str = ""
    platform: str = ""
    created_at: datetime = Field(default_factory=_utcnow)
