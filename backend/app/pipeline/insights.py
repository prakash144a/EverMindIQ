"""Insights: summarize memories over a time range with map-reduce, cached per range/day."""

from __future__ import annotations

from datetime import date, timedelta

from app.models.insight import Insight, InsightRange, InsightRequest
from app.services.firestore import get_repository
from app.services.gemini import get_gemini


def resolve_range(req: InsightRequest, today: date) -> tuple[date, date]:
    """Return (from, to) for a range relative to `today`. `custom` uses provided dates."""
    if req.range is InsightRange.custom:
        if not (req.date_from and req.date_to):
            raise ValueError("custom range requires date_from and date_to")
        return req.date_from, req.date_to

    to = today
    deltas = {
        InsightRange.day: timedelta(days=1),
        InsightRange.week: timedelta(weeks=1),
        InsightRange.month: timedelta(days=30),
        InsightRange.year: timedelta(days=365),
        InsightRange.five_years: timedelta(days=365 * 5),
    }
    if req.range is InsightRange.lifetime:
        return date(1900, 1, 1), to
    return to - deltas[req.range], to


def _cache_id(rng: InsightRange, lo: date, hi: date) -> str:
    return f"{rng.value}:{lo.isoformat()}:{hi.isoformat()}"


def generate_insight(uid: str, req: InsightRequest, today: date | None = None) -> Insight:
    today = today or date.today()
    lo, hi = resolve_range(req, today)
    repo = get_repository()

    cache_id = _cache_id(req.range, lo, hi)
    if not req.refresh:
        cached = repo.get_cached_insight(uid, cache_id)
        if cached is not None:
            return cached

    recordings = repo.list_recordings(uid, date_from=lo, date_to=hi)
    blocks = [
        f"[{r.event_date.isoformat()}] {r.title}: {r.summary or r.transcript[:160]}"
        for r in recordings
    ]
    answer_language = req.answer_language or repo.get_settings_doc(uid).answer_language
    summary, themes = get_gemini().summarize_range(blocks, answer_language)

    insight = Insight(
        id=cache_id,
        range=req.range,
        date_from=lo,
        date_to=hi,
        summary=summary,
        themes=themes,
        recording_count=len(recordings),
    )
    repo.save_insight(uid, insight)
    return insight
