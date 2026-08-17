from datetime import date

from app.models.insight import InsightRange, InsightRequest
from app.pipeline.insights import generate_insight, resolve_range
from app.pipeline.memories import build_on_this_day
from tests.conftest import auth


def test_resolve_range_week():
    req = InsightRequest(range=InsightRange.week)
    lo, hi = resolve_range(req, date(2026, 8, 7))
    assert hi == date(2026, 8, 7)
    assert lo == date(2026, 7, 31)


def test_custom_range_requires_dates():
    import pytest

    with pytest.raises(ValueError):
        resolve_range(InsightRequest(range=InsightRange.custom), date(2026, 8, 7))


def test_insight_summarizes_and_caches(make_recording):
    make_recording(
        "alice", "Started learning the piano this week.", event_date=date.today().isoformat()
    )
    first = generate_insight("alice", InsightRequest(range=InsightRange.lifetime))
    assert first.recording_count == 1
    assert first.summary
    # Second call is served from cache (same object id).
    cached = generate_insight("alice", InsightRequest(range=InsightRange.lifetime))
    assert cached.id == first.id


def test_insights_endpoint(make_recording, client):
    make_recording("alice", "A memory today.")
    r = client.post("/insights", json={"range": "lifetime"}, headers=auth("alice"))
    assert r.status_code == 200
    assert r.json()["range"] == "lifetime"


def test_on_this_day_surfaces_anniversary(make_recording):
    today = date.today()
    one_year_ago = today.replace(year=today.year - 1).isoformat()
    make_recording("alice", "Graduation day!", event_date=one_year_ago)

    feed = build_on_this_day("alice", today)
    assert len(feed.items) == 1
    assert feed.items[0].years_ago == 1
    assert feed.items[0].reason == "1 year ago today"


def test_on_this_day_endpoint(make_recording, client):
    today = date.today()
    make_recording("alice", "Old memory", event_date=today.replace(year=today.year - 5).isoformat())
    r = client.get("/memories/on-this-day", headers=auth("alice"))
    assert r.status_code == 200
    assert r.json()["items"][0]["years_ago"] == 5
