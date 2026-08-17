"""Activity tracking, and the throttle that keeps it affordable.

This app polls `GET /recordings` up to 24 times while a single transcript is in
flight. Writing a record on every request would turn one recording into two
dozen writes — the exact write-amplification shape `docs/milestones.md` Phase 4
already tracks. The in-process cache is what prevents that.
"""

from app.core import activity
from app.services.firestore import get_repository
from tests.conftest import admin_auth, auth


def headers(uid: str, install_id: str = "install-1") -> dict:
    return {
        **auth(uid),
        "X-Install-Id": install_id,
        "X-Platform": "android",
        "X-App-Version": "1.4.2",
    }


def test_device_details_are_captured_from_the_headers(client):
    client.get("/recordings", headers=headers("alice"))

    stats = get_repository().get_user_stats("alice")
    assert stats.install_id == "install-1"
    assert stats.platform == "android"
    assert stats.app_version == "1.4.2"


def test_repeat_requests_do_not_write_again(client, monkeypatch):
    repo = get_repository()
    calls: list[str] = []
    original = repo.touch_activity

    def counting(uid, install_id, platform, app_version):
        calls.append(uid)
        return original(uid, install_id, platform, app_version)

    monkeypatch.setattr(repo, "touch_activity", counting)

    for _ in range(5):
        client.get("/recordings", headers=headers("alice"))

    assert calls == ["alice"], "only the first request of the day should write"


def test_a_different_device_breaks_the_throttle(client):
    """Switching accounts or devices must register immediately, otherwise the
    console would miss the very relationship it exists to show."""
    client.get("/recordings", headers=headers("alice", "phone"))
    client.get("/recordings", headers=headers("alice", "tablet"))

    body = client.get("/admin/users/alice", headers=admin_auth()).json()
    assert {d["install_id"] for d in body["devices"]} == {"phone", "tablet"}


def test_each_user_is_throttled_independently(client):
    client.get("/recordings", headers=headers("alice"))
    client.get("/recordings", headers=headers("bob"))

    assert get_repository().get_user_stats("alice") is not None
    assert get_repository().get_user_stats("bob") is not None


def test_a_failure_to_record_activity_does_not_fail_the_request(client, monkeypatch):
    """Bookkeeping must never cost the user their request."""
    repo = get_repository()

    def boom(*_args, **_kwargs):
        raise RuntimeError("firestore is down")

    monkeypatch.setattr(repo, "touch_activity", boom)

    r = client.get("/recordings", headers=headers("alice"))
    assert r.status_code == 200


def test_missing_device_headers_are_tolerated(client):
    r = client.get("/recordings", headers=auth("alice"))
    assert r.status_code == 200
    assert get_repository().get_user_stats("alice").install_id == ""


def test_admin_browsing_is_not_counted_as_user_activity(client):
    """Otherwise the operator inflates their own daily-active number."""
    client.get("/admin/overview", headers=admin_auth())
    client.get("/admin/users", headers=admin_auth())

    from tests.conftest import ADMIN_UID

    assert get_repository().get_user_stats(ADMIN_UID) is None
    assert client.get("/admin/overview", headers=admin_auth()).json()["users_total"] == 0


def test_the_cache_is_bounded(client, monkeypatch):
    """A long-lived instance must not accumulate an entry per user forever."""
    monkeypatch.setattr(activity, "_MAX_SEEN", 3)
    for i in range(5):
        client.get("/recordings", headers=headers(f"user-{i}"))
    assert len(activity._seen) <= 3


def test_oversized_header_values_are_truncated(client):
    """Headers are attacker-controlled; nothing unbounded reaches the store."""
    client.get(
        "/recordings",
        headers={**auth("alice"), "X-Install-Id": "x" * 500, "X-Platform": "y" * 500},
    )
    stats = get_repository().get_user_stats("alice")
    assert len(stats.install_id) == 128
    assert len(stats.platform) == 64
