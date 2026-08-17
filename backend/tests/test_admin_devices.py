"""Devices and the accounts on them.

The planned switch-account feature means one phone will host several accounts:
sign out, sign in with a different email, same device. The install id is device
state and survives sign-out, which is exactly what lets the console show that
relationship. It runs the other way too — one account can appear on several
devices, via a second phone or a reinstall.
"""

from tests.conftest import admin_auth, auth


def device(uid: str, install_id: str, platform: str = "android", version: str = "1.0.0") -> dict:
    return {
        **auth(uid),
        "X-Install-Id": install_id,
        "X-Platform": platform,
        "X-App-Version": version,
    }


def _seen(client, uid: str, install_id: str, **kw) -> None:
    """Any authenticated call on a tracked router registers the device."""
    client.get("/recordings", headers=device(uid, install_id, **kw))


def test_device_headers_are_recorded_on_the_account(client):
    _seen(client, "alice", "install-a", platform="android", version="1.2.3")

    row = client.get("/admin/users/alice", headers=admin_auth()).json()["user"]
    assert row["install_id"] == "install-a"
    assert row["platform"] == "android"
    assert row["app_version"] == "1.2.3"


def test_two_accounts_on_one_device_are_both_listed(client):
    """The switch-account case: same phone, different emails."""
    _seen(client, "alice", "shared-phone")
    _seen(client, "bob", "shared-phone")

    body = client.get("/admin/devices/shared-phone", headers=admin_auth()).json()

    assert body["device"]["account_count"] == 2
    assert {a["uid"] for a in body["accounts"]} == {"alice", "bob"}


def test_a_shared_device_is_flagged_in_the_overview(client):
    _seen(client, "alice", "shared-phone")
    _seen(client, "bob", "shared-phone")
    _seen(client, "carol", "solo-phone")

    body = client.get("/admin/overview", headers=admin_auth()).json()
    assert body["devices_total"] == 2
    assert body["multi_account_devices"] == 1


def test_the_device_row_carries_each_accounts_email(client):
    client.post(
        "/profile", json={"preferred_name": "Alice"}, headers=device("alice", "shared-phone")
    )
    _seen(client, "alice", "shared-phone")
    _seen(client, "bob", "shared-phone")

    accounts = client.get("/admin/devices/shared-phone", headers=admin_auth()).json()["accounts"]
    by_uid = {a["uid"]: a for a in accounts}
    assert set(by_uid) == {"alice", "bob"}


def test_one_account_across_several_devices(client):
    _seen(client, "alice", "phone")
    _seen(client, "alice", "tablet")

    devices = client.get("/admin/users/alice", headers=admin_auth()).json()["devices"]
    assert {d["install_id"] for d in devices} == {"phone", "tablet"}

    # The most recent device is the one shown in the list column.
    row = client.get("/admin/users/alice", headers=admin_auth()).json()["user"]
    assert row["install_id"] == "tablet"


def test_purging_one_account_leaves_the_others_on_that_device(client):
    _seen(client, "alice", "shared-phone")
    _seen(client, "bob", "shared-phone")

    assert client.delete("/account", headers=auth("alice")).status_code == 204

    body = client.get("/admin/devices/shared-phone", headers=admin_auth()).json()
    assert [a["uid"] for a in body["accounts"]] == ["bob"]
    assert body["device"]["account_count"] == 1


def test_purging_the_last_account_removes_the_device(client):
    """The install id lives only on the stats record and the device link, which
    is what makes it genuinely deletable on request."""
    _seen(client, "alice", "solo-phone")

    client.delete("/account", headers=auth("alice"))

    assert client.get("/admin/devices/solo-phone", headers=admin_auth()).status_code == 404


def test_requests_without_device_headers_still_work(client):
    """Older builds, and the /live socket, send no device headers."""
    assert client.get("/recordings", headers=auth("alice")).status_code == 200
    row = client.get("/admin/users/alice", headers=admin_auth()).json()["user"]
    assert row["install_id"] == ""


def test_devices_are_listed_newest_first(client):
    _seen(client, "alice", "phone-1")
    _seen(client, "bob", "phone-2")

    items = client.get("/admin/devices", headers=admin_auth()).json()["items"]
    assert [d["install_id"] for d in items] == ["phone-2", "phone-1"]


def test_an_unknown_device_is_a_404(client):
    assert client.get("/admin/devices/nope", headers=admin_auth()).status_code == 404
