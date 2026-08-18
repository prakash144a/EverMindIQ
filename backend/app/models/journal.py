"""Journals: named containers the user files memories into.

One journal per memory, not many. Tags already cover the many-to-many case, and
the point of a journal is that Recall can be scoped to it — "answer from my
Travel journal alone" is a partition, and a memory belonging to three journals
would make that phrase mean nothing.

The name is user-authored and therefore *content*: "Therapy", "Divorce", "Baby"
say as much about a person as any transcript. Nothing here may reach an `/admin`
response (see `api/routers/admin.py` and `tests/test_admin_privacy.py`).
"""

from __future__ import annotations

from datetime import datetime, timezone

from pydantic import BaseModel, Field

# Long enough for "Conversations with Amma", short enough to render in a chip.
MAX_NAME_LEN = 40


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


class Journal(BaseModel):
    id: str
    name: str = Field(..., min_length=1, max_length=MAX_NAME_LEN)
    # Index into the app's palette rather than a hex string: the server has no
    # business knowing the theme, and this stays correct in dark mode.
    color_index: int = 0
    created_at: datetime = Field(default_factory=_utcnow)
    updated_at: datetime = Field(default_factory=_utcnow)


class JournalCreate(BaseModel):
    name: str = Field(..., min_length=1, max_length=MAX_NAME_LEN)
    color_index: int = 0


class JournalUpdate(BaseModel):
    """Fields the user can edit later. Omitted fields are left alone."""

    name: str | None = Field(default=None, min_length=1, max_length=MAX_NAME_LEN)
    color_index: int | None = None


__all__ = ["MAX_NAME_LEN", "Journal", "JournalCreate", "JournalUpdate"]
