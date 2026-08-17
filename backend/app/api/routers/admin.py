"""Operator console API.

Two things about this module are load-bearing.

**Authorization is a router-level dependency**, not a per-endpoint one, so a new
route cannot accidentally ship unguarded. An empty allowlist denies everyone.

**No endpoint here returns the content of anyone's memories.** Not the
transcript, not the summary, not the title, not the tags, people, places, or
mood. Those are generated *descriptions of the content* and are among the most
revealing things stored — `people` and `places` are literally the names of a
user's family and home. The rule is enforced structurally by the response models
in `app/models/admin.py`, which have no fields for them, and by
`tests/test_admin_privacy.py`. It is not a configurable setting, because a flag
that can be turned on is a flag that has to be disclosed and can be turned on at
2am while debugging.

The single deliberate exception is feedback text: the user typed that into a
"report a problem" box specifically so a human would read it.
"""

from __future__ import annotations

import logging
import uuid
from datetime import date, datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, Query, status

from app.core.security import CurrentUser, require_admin
from app.models.admin import (
    AdminAuditEntry,
    AdminAuditPage,
    AdminCount,
    AdminDevicePage,
    AdminFeedbackPage,
    AdminFeedbackPatch,
    AdminFeedbackRow,
    AdminHistogram,
    AdminMe,
    AdminOverview,
    AdminRecordingRow,
    AdminTimeSeries,
    AdminUserDetail,
    AdminUserPage,
    AdminUserPatch,
    AdminUserRow,
    DeviceDetail,
    FeedbackTriage,
    HistogramBucket,
    TimeSeriesPoint,
    bucket_labels,
)
from app.services.firestore import SORTABLE, get_repository
from app.services.storage import get_storage

router = APIRouter(prefix="/admin", tags=["admin"], dependencies=[Depends(require_admin)])

log = logging.getLogger(__name__)

# A 90-day chart is 90 document reads. An unbounded range would let a typo like
# date_from=2000-01-01 issue thousands.
MAX_RANGE_DAYS = 366

TIMESERIES_METRICS = (
    "new_users",
    "email_signups",
    "recordings",
    "recording_seconds",
    "active_users",
)


# ======================================================================
# Identity
# ======================================================================


@router.get("/me", response_model=AdminMe)
def whoami(admin: CurrentUser = Depends(require_admin)) -> AdminMe:
    return AdminMe(uid=admin.uid, email=admin.email or "")


# ======================================================================
# Overview
# ======================================================================


@router.get("/overview", response_model=AdminOverview)
def overview() -> AdminOverview:
    """Headline numbers.

    Computed from aggregation queries over the denormalized `userStats`
    collection rather than by walking each user's recordings, which would be
    O(users x recordings) reads on every page load.
    """
    return AdminOverview(**get_repository().global_summary())


# ======================================================================
# Users
#
# NB: literal paths must be declared before `/users/{uid}`, or FastAPI matches
# "count" as a uid.
# ======================================================================


@router.get("/users/count", response_model=AdminCount)
def count_users(
    tier: str | None = Query(default=None),
    active_days: int | None = Query(default=None, ge=1, le=MAX_RANGE_DAYS),
) -> AdminCount:
    since = _days_ago(active_days) if active_days else None
    return AdminCount(value=get_repository().count_user_stats(tier=tier, active_since=since))


@router.get("/users", response_model=AdminUserPage)
def list_users(
    limit: int = Query(default=50, ge=1, le=200),
    cursor: str | None = Query(default=None),
    sort: str = Query(default="last_active_at"),
    order: str = Query(default="desc", pattern="^(asc|desc)$"),
    tier: str | None = Query(default=None),
    platform: str | None = Query(default=None),
    q: str | None = Query(default=None, max_length=254),
) -> AdminUserPage:
    """Paginated user list.

    `q` matches an email, a display name, or a uid **by prefix** — Firestore has
    no substring search at any price, so a "contains" filter is not on offer.
    A search also forces the sort onto the searched field, because Firestore
    requires the first order_by to match the inequality; the effective sort is
    reported back in `sorted_by` rather than letting the UI claim otherwise.
    """
    if sort not in SORTABLE:
        # Literal 422: the named constant was renamed in Starlette and the old
        # spelling now warns. Matches the same workaround in `auth.py`.
        raise HTTPException(
            status_code=422,
            detail=f"sort must be one of {', '.join(SORTABLE)}",
        )
    rows, next_cursor = get_repository().list_user_stats(
        sort=sort, order=order, limit=limit, cursor=cursor, tier=tier, platform=platform, query=q
    )
    return AdminUserPage(
        items=[AdminUserRow.of(r) for r in rows],
        next_cursor=next_cursor,
        sorted_by="email" if q else sort,
    )


@router.get("/users/{uid}", response_model=AdminUserDetail)
def get_user(
    uid: str,
    recordings_limit: int = Query(default=20, ge=1, le=100),
    admin: CurrentUser = Depends(require_admin),
) -> AdminUserDetail:
    repo = get_repository()
    stats = repo.get_user_stats(uid)
    if stats is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="User not found")
    # Reading someone's account detail leaves a trail in Cloud Logging even
    # though it is a read and changes nothing.
    log.info("admin %s viewed user %s", admin.uid, uid)
    recordings = repo.list_recordings(uid)[:recordings_limit]
    return AdminUserDetail(
        user=AdminUserRow.of(stats),
        note=stats.note,
        tier_updated_at=stats.tier_updated_at,
        tier_updated_by=stats.tier_updated_by,
        previous_uids=stats.previous_uids,
        devices=repo.list_devices_for_user(uid),
        recent_recordings=[AdminRecordingRow.of(r) for r in recordings],
    )


@router.patch("/users/{uid}", response_model=AdminUserRow)
def update_user(
    uid: str,
    body: AdminUserPatch,
    admin: CurrentUser = Depends(require_admin),
) -> AdminUserRow:
    """Set operator-owned fields.

    Only tier and note. The display name and email belong to the user, and the
    email additionally backs the `emailIndex` lookup — editing it here would
    desynchronize that index and break account recovery.
    """
    repo = get_repository()
    before = repo.get_user_stats(uid)
    if before is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="User not found")
    previous_tier = before.tier
    stats = repo.set_tier(uid, body.tier, body.note, admin.uid)
    if stats is None:  # pragma: no cover - only if the row vanished mid-request
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="User not found")
    if body.tier is not None and body.tier != previous_tier:
        _audit(admin, "set_tier", uid, f"{previous_tier.value} -> {body.tier.value}")
    return AdminUserRow.of(stats)


@router.post("/users/{uid}/recompute-stats", response_model=AdminUserRow)
def recompute_stats(uid: str, admin: CurrentUser = Depends(require_admin)) -> AdminUserRow:
    """Rebuild one user's counters from their recordings.

    Bounded to a single account on purpose. The incremental counters can drift
    from a partial failure, and `max_duration_sec` is a high-water mark that
    deletions never lower — this is the exact re-derivation for both. There is
    deliberately no "recompute everything" endpoint: that scan belongs in
    `scripts/backfill_user_stats.py`, where it cannot time out a request or
    surprise the Firestore bill.
    """
    stats = get_repository().recompute_user_stats(uid)
    if stats is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="User not found")
    _audit(admin, "recompute_stats", uid, "")
    return AdminUserRow.of(stats)


@router.delete("/users/{uid}", status_code=status.HTTP_204_NO_CONTENT)
def purge_user(
    uid: str,
    confirm_uid: str = Query(...),
    admin: CurrentUser = Depends(require_admin),
) -> None:
    """Delete an account and everything in it.

    `confirm_uid` must repeat the path uid. Irreversibly destroying somebody's
    life memories should take more than one mis-click, and the check belongs
    here rather than only in the console, where a stray script would bypass it.
    """
    if confirm_uid != uid:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="confirm_uid must match the uid being deleted",
        )
    repo = get_repository()
    if repo.get_user_stats(uid) is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="User not found")
    repo.delete_user(uid)
    try:
        get_storage().delete_user_prefix(uid)
    except Exception:  # pragma: no cover - real-path failure
        log.exception("failed to purge audio objects for uid %s", uid)
    _audit(admin, "purge_user", uid, "")


# ======================================================================
# Devices — the switch-account view
# ======================================================================


@router.get("/devices", response_model=AdminDevicePage)
def list_devices(
    limit: int = Query(default=50, ge=1, le=200),
    cursor: str | None = Query(default=None),
) -> AdminDevicePage:
    rows, next_cursor = get_repository().list_devices(limit=limit, cursor=cursor)
    return AdminDevicePage(items=rows, next_cursor=next_cursor)


@router.get("/devices/{install_id}", response_model=DeviceDetail)
def get_device(install_id: str) -> DeviceDetail:
    """Every account that has signed in on one device.

    This is what makes the switch-account feature legible: one phone, several
    accounts, each with its own email. The device keeps its install id across
    sign-out, which is precisely what links them.
    """
    repo = get_repository()
    device = repo.get_device(install_id)
    if device is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Device not found")
    return DeviceDetail(device=device, accounts=repo.list_device_accounts(install_id))


# ======================================================================
# Feedback inbox
# ======================================================================


@router.get("/feedback", response_model=AdminFeedbackPage)
def list_feedback(
    limit: int = Query(default=50, ge=1, le=200),
    cursor: str | None = Query(default=None),
    kind: str | None = Query(default=None),
    platform: str | None = Query(default=None),
) -> AdminFeedbackPage:
    """Problem reports across all users, newest first.

    Until now nothing could read these: `GET /feedback` returns only the
    caller's own. Since app errors reach the server *only* as `diagnostics`
    attached to a report, this is the only crash channel that exists.
    """
    repo = get_repository()
    rows, next_cursor = repo.list_all_feedback(
        limit=limit, cursor=cursor, kind=kind, platform=platform
    )
    items = []
    for item in rows:
        triage = repo.get_triage(item.id)
        items.append(
            AdminFeedbackRow(
                id=item.id,
                uid=item.uid,
                kind=item.kind.value,
                message=item.message,
                diagnostics=item.diagnostics,
                app_version=item.app_version,
                platform=item.platform,
                created_at=item.created_at,
                status=triage.status if triage else "new",
                admin_note=triage.admin_note if triage else "",
            )
        )
    return AdminFeedbackPage(items=items, next_cursor=next_cursor)


@router.patch("/feedback/{feedback_id}", response_model=FeedbackTriage)
def update_feedback(
    feedback_id: str,
    body: AdminFeedbackPatch,
    admin: CurrentUser = Depends(require_admin),
) -> FeedbackTriage:
    """Triage state lives in its own collection, not on the feedback document.

    `users/{uid}/feedback/{id}` is writable by the user who created it, so a
    status stored there could be flipped back by the reporter.
    """
    repo = get_repository()
    triage = repo.get_triage(feedback_id) or FeedbackTriage(feedback_id=feedback_id)
    if body.status is not None:
        triage.status = body.status
    if body.admin_note is not None:
        triage.admin_note = body.admin_note
    triage.updated_at = datetime.now(timezone.utc)
    triage.updated_by = admin.uid
    return repo.save_triage(triage)


# ======================================================================
# Pipeline health
# ======================================================================


@router.get("/recordings/failed", response_model=list[AdminRecordingRow])
def failed_recordings(limit: int = Query(default=50, ge=1, le=200)) -> list[AdminRecordingRow]:
    """Recordings that failed to ingest, or are stuck mid-transcription.

    Invisible today: a user just sees a memory whose transcript never arrives.
    """
    return [AdminRecordingRow.of(r) for r in get_repository().list_failed_recordings(limit)]


# ======================================================================
# Charts
# ======================================================================


@router.get("/metrics/timeseries", response_model=AdminTimeSeries)
def timeseries(
    metric: str = Query(...),
    date_from: date | None = Query(default=None),
    date_to: date | None = Query(default=None),
) -> AdminTimeSeries:
    if metric not in TIMESERIES_METRICS:
        # Literal 422: the named constant was renamed in Starlette and the old
        # spelling now warns. Matches the same workaround in `auth.py`.
        raise HTTPException(
            status_code=422,
            detail=f"metric must be one of {', '.join(TIMESERIES_METRICS)}",
        )
    start, end = _resolve_range(date_from, date_to)
    rows = get_repository().list_daily(start, end)
    return AdminTimeSeries(
        metric=metric,
        points=[TimeSeriesPoint(day=r.day, value=float(getattr(r, metric))) for r in rows],
    )


@router.get("/metrics/duration-histogram", response_model=AdminHistogram)
def duration_histogram(
    date_from: date | None = Query(default=None),
    date_to: date | None = Query(default=None),
) -> AdminHistogram:
    """How long recordings actually are.

    This is the better answer to "how long do users expect to record for" than
    any single maximum, which by definition describes one outlier. Percentiles
    are interpolated from bucket counts and named `_approx` accordingly.
    """
    start, end = _resolve_range(date_from, date_to)
    repo = get_repository()
    totals: dict[str, int] = {label: 0 for label in bucket_labels()}
    for row in repo.list_daily(start, end):
        for label, count in row.duration_buckets.items():
            totals[label] = totals.get(label, 0) + count

    buckets = [
        HistogramBucket(label=label, count=totals.get(label, 0)) for label in bucket_labels()
    ]
    total = sum(b.count for b in buckets)
    return AdminHistogram(
        buckets=buckets,
        total=total,
        p50_approx=_percentile(buckets, total, 0.50),
        p90_approx=_percentile(buckets, total, 0.90),
        max_duration_sec=repo.global_summary()["max_duration_sec"],
    )


# ======================================================================
# Audit
# ======================================================================


@router.get("/audit", response_model=AdminAuditPage)
def list_audit(limit: int = Query(default=100, ge=1, le=500)) -> AdminAuditPage:
    return AdminAuditPage(items=get_repository().list_audit(limit))


# ======================================================================
# Helpers
# ======================================================================


def _audit(admin: CurrentUser, action: str, target: str, detail: str) -> None:
    """Record a mutation. Best effort — never block the action it describes."""
    try:
        get_repository().add_audit(
            AdminAuditEntry(
                id=uuid.uuid4().hex,
                admin_uid=admin.uid,
                admin_email=admin.email or "",
                action=action,
                target=target,
                detail=detail,
            )
        )
    except Exception:  # pragma: no cover - bookkeeping only
        log.exception("failed to write audit entry %s on %s", action, target)


def _days_ago(days: int) -> datetime:
    return datetime.now(timezone.utc) - timedelta(days=days)


def _resolve_range(date_from: date | None, date_to: date | None) -> tuple[date, date]:
    end = date_to or datetime.now(timezone.utc).date()
    start = date_from or (end - timedelta(days=29))
    if start > end:
        # Literal 422: the named constant was renamed in Starlette and the old
        # spelling now warns. Matches the same workaround in `auth.py`.
        raise HTTPException(
            status_code=422,
            detail="date_from must not be after date_to",
        )
    if (end - start).days > MAX_RANGE_DAYS:
        # Literal 422: the named constant was renamed in Starlette and the old
        # spelling now warns. Matches the same workaround in `auth.py`.
        raise HTTPException(
            status_code=422,
            detail=f"range must be {MAX_RANGE_DAYS} days or fewer",
        )
    return start, end


def _percentile(buckets: list[HistogramBucket], total: int, fraction: float) -> float:
    """Interpolate a percentile from bucket counts.

    Approximate by construction — the underlying durations are not retained,
    only their bucket. Returns the upper edge of the bucket the percentile falls
    in, which is the honest resolution this data supports.
    """
    if total <= 0:
        return 0.0
    target = total * fraction
    seen = 0
    for bucket in buckets:
        seen += bucket.count
        if seen >= target:
            edge = bucket.label.split("-")[-1].rstrip("+")
            return float(edge) if edge.isdigit() else float(bucket.label.rstrip("+"))
    return 0.0
