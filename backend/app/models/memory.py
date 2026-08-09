from __future__ import annotations

from datetime import date

from pydantic import BaseModel, Field


class MemoryItem(BaseModel):
    recording_id: str
    event_date: date
    title: str
    summary: str
    years_ago: int
    reason: str  # e.g. "1 year ago today", "5 years ago", "milestone"


class MemoryFeed(BaseModel):
    for_date: date
    items: list[MemoryItem] = Field(default_factory=list)
