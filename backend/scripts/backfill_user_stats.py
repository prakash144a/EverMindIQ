"""Build `userStats` for accounts that predate it.

Run once, locally, against a real project. Deliberately not an admin endpoint:
this is O(users x recordings) reads and would exceed a Cloud Run request timeout
long before it finished, while quietly costing real money.

    python scripts/backfill_user_stats.py --project voiceiq-505205
    python scripts/backfill_user_stats.py --project voiceiq-505205 --apply

Dry run by default; nothing is written until `--apply`.

The interesting part is finding the users at all. Firestore does not require a
parent document to exist for its subcollections to hold data, and this project
has already hit that for real — `users/{uid}` returning 404 while its
`recordings` subcollection still held documents. Anyone who recorded without
ever saving a setting or verifying an email is invisible to
`collection("users").stream()`, so three sources are combined below. A user list
that quietly under-reports is worse than no user list.
"""

from __future__ import annotations

import argparse
import sys

# Runs from the backend/ directory as `python scripts/backfill_user_stats.py`.
sys.path.insert(0, ".")

from app.models.admin import DailyStats, bucket_label  # noqa: E402
from app.models.user import UserProfile, UserStats  # noqa: E402
from app.services import stats as stats_ops  # noqa: E402


def discover_uids(db) -> set[str]:
    """Every uid with data, from three sources — none of which is complete alone."""
    uids: set[str] = set()

    # 1. `list_documents` is the specific API that returns references to parent
    #    documents that do NOT exist but have subcollections. This is the whole
    #    reason the script exists.
    for ref in db.collection("users").list_documents():
        uids.add(ref.id)

    # 2. Verified accounts, whose user document may have been deleted by a merge.
    for snap in db.collection("emailIndex").stream():
        uid = (snap.to_dict() or {}).get("uid")
        if uid:
            uids.add(uid)

    # 3. Anything already backfilled, so re-runs converge instead of drifting.
    for snap in db.collection("userStats").stream():
        uids.add(snap.id)

    return uids


def build_stats(db, uid: str) -> tuple[UserStats, list[tuple[str, float]]]:
    """Recompute one account from its own documents.

    Returns the stats plus (day, duration) pairs for rebuilding the daily
    rollups in the same pass.
    """
    from app.models.recording import Recording

    recordings = [
        Recording(**snap.to_dict())
        for snap in db.collection("users").document(uid).collection("recordings").stream()
    ]
    feedback = list(db.collection("users").document(uid).collection("feedback").stream())

    stats = stats_ops.new_stats(uid)
    # Overwrite rather than increment, so running this twice is a no-op rather
    # than a doubling.
    stats_ops.recompute(stats, recordings, len(feedback))

    snap = db.collection("users").document(uid).get()
    profile_data = (snap.to_dict() or {}).get("profile") if snap.exists else None
    if profile_data:
        profile = UserProfile(**profile_data)
        stats_ops.apply_identity(
            stats, profile.preferred_name, profile.email, profile.email_verified
        )
        stats.created_at = profile.created_at
        stats.signup_day = profile.created_at.date()

    if stats.first_recorded_at and stats.first_recorded_at < stats.created_at:
        stats.created_at = stats.first_recorded_at
        stats.signup_day = stats.first_recorded_at.date()
    if stats.last_recording_at:
        stats.last_active_at = max(stats.last_active_at, stats.last_recording_at)
        stats.last_active_day = stats.last_active_at.date()

    days = [(r.created_at.date().isoformat(), r.duration_sec) for r in recordings]
    return stats, days


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    # No default: pointing this at the wrong project should require saying so.
    parser.add_argument("--project", required=True, help="GCP project id")
    parser.add_argument("--apply", action="store_true", help="write (default is a dry run)")
    parser.add_argument("--limit", type=int, default=0, help="stop after N users (smoke test)")
    args = parser.parse_args()

    from google.cloud import firestore

    db = firestore.Client(project=args.project)

    uids = sorted(discover_uids(db))
    if args.limit:
        uids = uids[: args.limit]
    print(f"{len(uids)} account(s) discovered in {args.project}")

    daily: dict[str, DailyStats] = {}
    written = 0
    for uid in uids:
        stats, days = build_stats(db, uid)
        existing = db.collection("userStats").document(uid).get()
        before = UserStats(**existing.to_dict()).recordings_count if existing.exists else None

        print(
            f"  {uid}: recordings {before if before is not None else '-'} -> "
            f"{stats.recordings_count}, longest {stats.max_duration_sec:.0f}s, "
            f"email {stats.email or '(anonymous)'}"
        )

        for day, duration in days:
            entry = daily.setdefault(day, DailyStats(day=stats.signup_day))
            entry.recordings += 1
            entry.recording_seconds += duration
            label = bucket_label(duration)
            entry.duration_buckets[label] = entry.duration_buckets.get(label, 0) + 1

        signup = daily.setdefault(stats.signup_day.isoformat(), DailyStats(day=stats.signup_day))
        signup.new_users += 1
        if stats.email_verified:
            signup.email_signups += 1

        if args.apply:
            db.collection("userStats").document(uid).set(stats.model_dump(mode="json"))
            written += 1

    if args.apply:
        for day, entry in daily.items():
            payload = entry.model_dump(mode="json")
            payload["day"] = day
            db.collection("dailyStats").document(day).set(payload)
        print(f"wrote {written} userStats and {len(daily)} dailyStats documents")
    else:
        print(f"dry run — nothing written. {len(daily)} daily rollup(s) would be rebuilt.")
        print("re-run with --apply to write.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
