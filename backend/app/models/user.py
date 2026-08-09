from __future__ import annotations

from pydantic import BaseModel, Field


class UserSettings(BaseModel):
    on_this_day_enabled: bool = True
    slideshow_interval_sec: int = 6
    notifications_enabled: bool = True
    # "auto" = answer in the language of the question; or an ISO code like "en".
    answer_language: str = "auto"
    retention_days: int = 0  # 0 = keep forever
