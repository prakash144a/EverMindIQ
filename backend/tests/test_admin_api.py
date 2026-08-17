"""The admin endpoints themselves: listing, paging, searching, mutating."""

from tests.conftest import ADMIN_UID, admin_auth, auth


def _record(client, uid: str, duration: float = 5.0) -> dict:
    up = client.post("/uploads", json={}, headers=auth(uid)).json()
    return client.post(
        "/recordings",
        json={"audio_path": up["audio_path"], "duration_sec": duration},
        headers=auth(uid),
    ).json()


def _seen(client, uid: str) -> None:
    client.get("/recordings", headers=auth(uid))


# -- overview -----------------------------------------------------------


def test_overview_counts_users_and_recordings(client):
    _record(client, "alice", 10.0)
    _record(client, "alice", 40.0)
    _record(client, "bob", 5.0)

    body = client.get("/admin/overview", headers=admin_auth()).json()

    assert body["users_total"] == 2
    assert body["recordings_total"] == 3
    assert body["total_duration_sec"] == 55.0
    assert body["max_duration_sec"] == 40.0
    assert body["active_1d"] == 2


def test_overview_separates_anonymous_from_registered(client):
    _seen(client, "alice")
    _seen(client, "bob")

    body = client.get("/admin/overview", headers=admin_auth()).json()
    assert body["users_anonymous"] == 2
    assert body["users_with_email"] == 0
    assert body["users_premium"] == 0


# -- user list ----------------------------------------------------------


def test_user_list_returns_a_row_per_account(client):
    _seen(client, "alice")
    _seen(client, "bob")

    body = client.get("/admin/users", headers=admin_auth()).json()
    assert {u["uid"] for u in body["items"]} == {"alice", "bob"}
    assert body["sorted_by"] == "last_active_at"


def test_user_list_paginates_without_skipping_or_repeating(client):
    for uid in ("u1", "u2", "u3", "u4", "u5"):
        _seen(client, uid)

    seen: list[str] = []
    cursor = None
    for _ in range(10):  # bounded, so a broken cursor cannot hang the suite
        url = "/admin/users?limit=2" + (f"&cursor={cursor}" if cursor else "")
        page = client.get(url, headers=admin_auth()).json()
        seen += [u["uid"] for u in page["items"]]
        cursor = page["next_cursor"]
        if not cursor:
            break

    assert sorted(seen) == ["u1", "u2", "u3", "u4", "u5"]
    assert len(seen) == len(set(seen)), "a row was returned on two pages"


def test_user_list_sorts_by_recording_count(client):
    _record(client, "quiet", 1.0)
    for _ in range(3):
        _record(client, "chatty", 1.0)

    body = client.get(
        "/admin/users?sort=recordings_count&order=desc", headers=admin_auth()
    ).json()
    assert [u["uid"] for u in body["items"]] == ["chatty", "quiet"]


def test_user_list_rejects_an_unindexed_sort(client):
    """A free-text sort would build a query no Firestore index supports."""
    r = client.get("/admin/users?sort=transcript", headers=admin_auth())
    assert r.status_code == 422


def test_user_list_filters_by_tier(client):
    _seen(client, "alice")
    _seen(client, "bob")
    client.patch("/admin/users/alice", json={"tier": "premium"}, headers=admin_auth())

    body = client.get("/admin/users?tier=premium", headers=admin_auth()).json()
    assert [u["uid"] for u in body["items"]] == ["alice"]


def test_user_search_matches_a_uid_prefix(client):
    _seen(client, "alice")
    _seen(client, "bob")

    body = client.get("/admin/users?q=ali", headers=admin_auth()).json()
    assert [u["uid"] for u in body["items"]] == ["alice"]


def test_search_reports_the_sort_it_actually_used(client):
    """Firestore forces the sort onto the searched field. Saying so beats
    letting the console label the column with a sort it did not get."""
    _seen(client, "alice")
    body = client.get("/admin/users?q=ali&sort=created_at", headers=admin_auth()).json()
    assert body["sorted_by"] == "email"


def test_user_count_is_a_separate_call(client):
    """Firestore cannot return a total alongside a page, so the count is its
    own endpoint rather than a field the page pretends to know."""
    _seen(client, "alice")
    _seen(client, "bob")
    assert client.get("/admin/users/count", headers=admin_auth()).json()["value"] == 2


def test_count_is_not_mistaken_for_a_uid(client):
    """Route ordering: `/users/count` must win over `/users/{uid}`."""
    r = client.get("/admin/users/count", headers=admin_auth())
    assert r.status_code == 200
    assert "value" in r.json()


# -- user detail and mutation ------------------------------------------


def test_user_detail_reports_counters_and_recordings(client):
    _record(client, "alice", 12.0)

    body = client.get("/admin/users/alice", headers=admin_auth()).json()
    assert body["user"]["recordings_count"] == 1
    assert body["user"]["max_duration_sec"] == 12.0
    assert len(body["recent_recordings"]) == 1


def test_unknown_user_is_a_404(client):
    assert client.get("/admin/users/ghost", headers=admin_auth()).status_code == 404


def test_setting_a_tier_records_who_did_it(client):
    _seen(client, "alice")

    r = client.patch("/admin/users/alice", json={"tier": "premium"}, headers=admin_auth())
    assert r.status_code == 200
    assert r.json()["tier"] == "premium"

    detail = client.get("/admin/users/alice", headers=admin_auth()).json()
    assert detail["tier_updated_by"] == ADMIN_UID
    assert detail["tier_updated_at"] is not None


def test_tier_can_be_taken_away_again(client):
    _seen(client, "alice")
    client.patch("/admin/users/alice", json={"tier": "premium"}, headers=admin_auth())
    r = client.patch("/admin/users/alice", json={"tier": "free"}, headers=admin_auth())
    assert r.json()["tier"] == "free"


def test_an_unknown_tier_is_rejected(client):
    _seen(client, "alice")
    r = client.patch("/admin/users/alice", json={"tier": "platinum"}, headers=admin_auth())
    assert r.status_code == 422


def test_setting_a_tier_on_an_unknown_user_is_a_404(client):
    r = client.patch("/admin/users/ghost", json={"tier": "premium"}, headers=admin_auth())
    assert r.status_code == 404


def test_a_note_can_be_set_without_touching_the_tier(client):
    _seen(client, "alice")
    client.patch("/admin/users/alice", json={"tier": "premium"}, headers=admin_auth())
    client.patch("/admin/users/alice", json={"note": "beta tester"}, headers=admin_auth())

    detail = client.get("/admin/users/alice", headers=admin_auth()).json()
    assert detail["note"] == "beta tester"
    assert detail["user"]["tier"] == "premium"


# -- purge --------------------------------------------------------------


def test_purge_requires_the_uid_to_be_repeated(client):
    _record(client, "alice")

    r = client.delete("/admin/users/alice?confirm_uid=bob", headers=admin_auth())
    assert r.status_code == 400
    assert client.get("/admin/users/alice", headers=admin_auth()).status_code == 200


def test_purge_removes_the_account(client):
    _record(client, "alice")

    r = client.delete("/admin/users/alice?confirm_uid=alice", headers=admin_auth())
    assert r.status_code == 204
    assert client.get("/admin/users/alice", headers=admin_auth()).status_code == 404
    assert client.get("/recordings", headers=auth("alice")).json() == []


# -- feedback inbox -----------------------------------------------------


def test_feedback_inbox_spans_every_user(client):
    client.post("/feedback", json={"kind": "problem", "message": "a"}, headers=auth("alice"))
    client.post("/feedback", json={"kind": "idea", "message": "b"}, headers=auth("bob"))

    body = client.get("/admin/feedback", headers=admin_auth()).json()
    assert {i["uid"] for i in body["items"]} == {"alice", "bob"}


def test_feedback_can_be_filtered_by_kind(client):
    client.post("/feedback", json={"kind": "problem", "message": "a"}, headers=auth("alice"))
    client.post("/feedback", json={"kind": "idea", "message": "b"}, headers=auth("bob"))

    body = client.get("/admin/feedback?kind=idea", headers=admin_auth()).json()
    assert [i["message"] for i in body["items"]] == ["b"]


def test_triage_state_persists_and_is_not_user_writable(client):
    client.post("/feedback", json={"kind": "problem", "message": "a"}, headers=auth("alice"))
    item_id = client.get("/admin/feedback", headers=admin_auth()).json()["items"][0]["id"]

    client.patch(
        f"/admin/feedback/{item_id}",
        json={"status": "resolved", "admin_note": "fixed in 1.1"},
        headers=admin_auth(),
    )

    row = client.get("/admin/feedback", headers=admin_auth()).json()["items"][0]
    assert row["status"] == "resolved"
    assert row["admin_note"] == "fixed in 1.1"
    # The user's own view is unchanged — triage lives outside their document.
    assert "resolved" not in client.get("/feedback", headers=auth("alice")).text


# -- audit --------------------------------------------------------------


def test_tier_changes_are_audited(client):
    _seen(client, "alice")
    client.patch("/admin/users/alice", json={"tier": "premium"}, headers=admin_auth())

    items = client.get("/admin/audit", headers=admin_auth()).json()["items"]
    assert items[0]["action"] == "set_tier"
    assert items[0]["target"] == "alice"
    assert items[0]["admin_uid"] == ADMIN_UID
    assert items[0]["detail"] == "free -> premium"


def test_a_tier_write_that_changes_nothing_is_not_audited(client):
    _seen(client, "alice")
    client.patch("/admin/users/alice", json={"tier": "free"}, headers=admin_auth())
    assert client.get("/admin/audit", headers=admin_auth()).json()["items"] == []


# -- pipeline health ----------------------------------------------------


def test_failed_recordings_are_surfaced(client, make_recording):
    from app.services.firestore import get_repository

    make_recording("alice", "some words")
    repo = get_repository()
    rec = repo.list_recordings("alice")[0]
    rec.status = "failed"
    repo.update_recording(rec)

    body = client.get("/admin/recordings/failed", headers=admin_auth()).json()
    assert [r["id"] for r in body] == [rec.id]
    assert body[0]["status"] == "failed"
