"""Chart data.

Counters are incremented at write time into one document per day, so a 90-day
chart costs 90 reads regardless of how many users or recordings exist. Reading
the raw collections instead would cost one read per recording, per page load.
"""

from datetime import datetime, timedelta, timezone

from tests.conftest import admin_auth, auth


def _record(client, uid: str, duration: float) -> dict:
    up = client.post("/uploads", json={}, headers=auth(uid)).json()
    return client.post(
        "/recordings",
        json={"audio_path": up["audio_path"], "duration_sec": duration},
        headers=auth(uid),
    ).json()


def _series(client, metric: str) -> list[dict]:
    r = client.get(f"/admin/metrics/timeseries?metric={metric}", headers=admin_auth())
    assert r.status_code == 200, r.text
    return r.json()["points"]


def test_recordings_are_counted_per_day(client):
    _record(client, "alice", 10.0)
    _record(client, "alice", 20.0)

    points = _series(client, "recordings")
    assert len(points) == 1
    assert points[0]["value"] == 2
    assert points[0]["day"] == datetime.now(timezone.utc).date().isoformat()


def test_recorded_seconds_accumulate(client):
    _record(client, "alice", 10.5)
    _record(client, "bob", 4.5)
    assert _series(client, "recording_seconds")[0]["value"] == 15.0


def test_a_new_account_is_counted_once(client):
    client.get("/recordings", headers=auth("alice"))
    client.get("/recordings", headers=auth("alice"))
    assert _series(client, "new_users")[0]["value"] == 1


def test_active_users_counts_each_person_once_per_day(client):
    """A naive counter would over-count every extra request. The repository
    decides by comparing the *stored* day, so the number stays exact even
    across instances that share no cache."""
    for _ in range(4):
        client.get("/recordings", headers=auth("alice"))
    client.get("/recordings", headers=auth("bob"))

    assert _series(client, "active_users")[0]["value"] == 2


def test_an_anonymous_start_is_a_new_user_but_not_a_signup(client):
    """`new_users` and `email_signups` are separate on purpose. Every user
    starts anonymous, and only verifying an email is a signup — conflating the
    two would make every reinstall and account switch look like growth."""
    client.get("/recordings", headers=auth("alice"))

    assert _series(client, "new_users")[0]["value"] == 1
    # The day exists in the rollup, so the point is present and zero rather
    # than absent.
    assert _series(client, "email_signups")[0]["value"] == 0


def _sign_up(client, uid: str, email: str) -> dict:
    client.post("/auth/otp/request", json={"email": email}, headers=auth(uid))
    code = client.post("/dev/last-otp", json={"email": email}, headers=auth(uid)).json()["code"]
    return client.post(
        "/auth/otp/verify", json={"email": email, "code": code}, headers=auth(uid)
    ).json()


def test_verifying_an_email_counts_as_a_signup(client):
    assert _sign_up(client, "alice", "alice@example.com")["status"] == "signed_up"
    assert _series(client, "email_signups")[0]["value"] == 1


def test_signing_in_again_is_not_a_second_signup(client):
    """Re-verifying an address you already own is the same account, not growth."""
    _sign_up(client, "alice", "alice@example.com")
    assert _sign_up(client, "alice", "alice@example.com")["status"] == "verified"

    assert _series(client, "email_signups")[0]["value"] == 1


def test_a_signup_shows_the_email_on_the_admin_row(client):
    _sign_up(client, "alice", "alice@example.com")

    row = client.get("/admin/users/alice", headers=admin_auth()).json()["user"]
    assert row["email"] == "alice@example.com"
    assert row["email_verified"] is True


def test_an_unknown_metric_is_rejected(client):
    r = client.get("/admin/metrics/timeseries?metric=revenue", headers=admin_auth())
    assert r.status_code == 422


def test_the_range_is_capped(client):
    """Without this, a stray date_from would issue thousands of reads."""
    r = client.get(
        "/admin/metrics/timeseries?metric=recordings&date_from=2000-01-01",
        headers=admin_auth(),
    )
    assert r.status_code == 422


def test_a_backwards_range_is_rejected(client):
    r = client.get(
        "/admin/metrics/timeseries?metric=recordings&date_from=2026-08-16&date_to=2026-08-01",
        headers=admin_auth(),
    )
    assert r.status_code == 422


def test_a_range_with_no_data_is_empty_not_an_error(client):
    old = (datetime.now(timezone.utc) - timedelta(days=200)).date()
    r = client.get(
        f"/admin/metrics/timeseries?metric=recordings&date_from={old}&date_to={old}",
        headers=admin_auth(),
    )
    assert r.status_code == 200
    assert r.json()["points"] == []


# -- histogram ----------------------------------------------------------


def test_durations_land_in_the_right_buckets(client):
    _record(client, "alice", 5.0)  # 0-15
    _record(client, "alice", 20.0)  # 15-30
    _record(client, "alice", 45.0)  # 30-60
    _record(client, "alice", 900.0)  # 600+

    body = client.get("/admin/metrics/duration-histogram", headers=admin_auth()).json()
    counts = {b["label"]: b["count"] for b in body["buckets"]}

    assert counts["0-15"] == 1
    assert counts["15-30"] == 1
    assert counts["30-60"] == 1
    assert counts["600+"] == 1
    assert body["total"] == 4


def test_the_histogram_reports_the_true_maximum(client):
    """The buckets are approximate by construction; the maximum is exact, and
    comes from a single ordered read rather than a scan."""
    _record(client, "alice", 5.0)
    _record(client, "alice", 412.0)

    body = client.get("/admin/metrics/duration-histogram", headers=admin_auth()).json()
    assert body["max_duration_sec"] == 412.0


def test_empty_buckets_are_still_present(client):
    """A chart needs a stable x-axis even before there is data."""
    body = client.get("/admin/metrics/duration-histogram", headers=admin_auth()).json()
    assert [b["label"] for b in body["buckets"]] == [
        "0-15",
        "15-30",
        "30-60",
        "60-120",
        "120-300",
        "300-600",
        "600+",
    ]
    assert body["total"] == 0
    assert body["p50_approx"] == 0.0


def test_percentiles_are_interpolated_from_the_buckets(client):
    for _ in range(9):
        _record(client, "alice", 5.0)
    _record(client, "alice", 900.0)

    body = client.get("/admin/metrics/duration-histogram", headers=admin_auth()).json()
    # Nine of ten recordings are in the first bucket, so both percentiles
    # resolve to its upper edge.
    assert body["p50_approx"] == 15.0
    assert body["p90_approx"] == 15.0
