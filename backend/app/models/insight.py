from __future__ import annotations

from datetime import date, datetime, timezone
from enum import Enum

from pydantic import BaseModel, Field


class InsightRange(str, Enum):
    day = "day"
    week = "week"
    month = "month"
    year = "year"
    five_years = "5y"
    lifetime = "lifetime"
    custom = "custom"


class InsightRequest(BaseModel):
    range: InsightRange
    # Required only for `custom`; otherwise derived server-side relative to today.
    date_from: date | None = None
    date_to: date | None = None
    answer_language: str | None = None
    refresh: bool = False  # bypass cache


class Insight(BaseModel):
    id: str
    range: InsightRange
    date_from: date
    date_to: date
    summary: str
    themes: list[str] = Field(default_factory=list)
    recording_count: int = 0
    generated_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
