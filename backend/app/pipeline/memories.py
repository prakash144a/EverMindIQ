"""'On This Day' feed: resurface anniversaries (N years ago today) and flagged milestones."""

from __future__ import annotations

from datetime import date

from app.models.memory import MemoryFeed, MemoryItem
from app.services.firestore import get_repository

# Anniversary horizons to surface, in years.
ANNIVERSARY_YEARS = (1, 2, 3, 5, 10, 15, 20, 25)


def build_on_this_day(uid: str, for_date: date | None = None) -> MemoryFeed:
    for_date = for_date or date.today()
    repo = get_repository()
    recordings = repo.list_recordings(uid)

    items: list[MemoryItem] = []
    seen: set[str] = set()
    for rec in recordings:
        ev = rec.event_date
        # Same calendar day, an exact number of years earlier.
        if ev.month == for_date.month and ev.day == for_date.day and ev.year < for_date.year:
            years = for_date.year - ev.year
            if years in ANNIVERSARY_YEARS:
                items.append(
                    MemoryItem(
                        recording_id=rec.id,
                        event_date=ev,
                        title=rec.title or "A memory",
                        summary=rec.summary,
                        years_ago=years,
                        reason=_reason(years),
                    )
                )
                seen.add(rec.id)

    # Also include milestones from any past year on this day-of-year is covered above; surface
    # milestones broadly is left to Phase 2. For now, prioritize anniversaries.
    items.sort(key=lambda i: i.years_ago)
    feed = MemoryFeed(for_date=for_date, items=items)
    repo.save_feed(uid, feed)
    return feed


def _reason(years: int) -> str:
    return "1 year ago today" if years == 1 else f"{years} years ago today"
