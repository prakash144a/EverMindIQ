from __future__ import annotations

from datetime import date

from fastapi import APIRouter, Depends, Query

from app.core.security import CurrentUser, get_current_user
from app.models.memory import MemoryFeed
from app.pipeline.memories import build_on_this_day
from app.services.firestore import get_repository

router = APIRouter(prefix="/memories", tags=["memories"])


@router.get("/on-this-day", response_model=MemoryFeed)
def on_this_day(
    for_date: date | None = Query(default=None),
    refresh: bool = Query(default=False),
    user: CurrentUser = Depends(get_current_user),
) -> MemoryFeed:
    """Home slideshow feed. Served from the precomputed feed unless `refresh` is set."""
    target = for_date or date.today()
    if not refresh:
        cached = get_repository().get_feed(user.uid, target)
        if cached is not None:
            return cached
    return build_on_this_day(user.uid, target)
