"""Journals: the containers, their tier ceiling, and what happens at the edges.

The entitlement here is a ceiling on *creation only*. Everything else — listing,
renaming, filing, deleting — stays open whatever the tier, so that a premium
subscription lapsing can never strand somebody's memories inside containers they
are no longer allowed to touch. Several tests below exist only to hold that line.
"""

from __future__ import annotations

from tests.conftest import auth, set_tier


def make_journal(client, uid: str, name: str) -> dict:
    resp = client.post("/journals", json={"name": name}, headers=auth(uid))
    assert resp.status_code == 201, resp.text
    return resp.json()


def file_text(client, uid: str, text: str, journal_id: str) -> dict:
    resp = client.post(
        "/recordings/text",
        json={"text": text, "journal_id": journal_id},
        headers=auth(uid),
    )
    assert resp.status_code == 201, resp.text
    return resp.json()


# -- basics -------------------------------------------------------------------


def test_a_new_account_has_no_journals(client):
    assert client.get("/journals", headers=auth("u1")).json() == []


def test_creating_a_journal_returns_it_and_it_lists(client):
    created = make_journal(client, "u1", "Travel")
    assert created["name"] == "Travel"
    assert created["id"]

    rows = client.get("/journals", headers=auth("u1")).json()
    assert [j["name"] for j in rows] == ["Travel"]


def test_journals_list_alphabetically_ignoring_case(client):
    set_tier("u1", "premium")
    for name in ("thoughts", "Travel", "Politics"):
        make_journal(client, "u1", name)

    rows = client.get("/journals", headers=auth("u1")).json()
    assert [j["name"] for j in rows] == ["Politics", "thoughts", "Travel"]


def test_journals_are_per_user(client):
    make_journal(client, "alice", "Travel")
    assert client.get("/journals", headers=auth("bob")).json() == []


def test_a_blank_name_is_refused(client):
    resp = client.post("/journals", json={"name": "   "}, headers=auth("u1"))
    assert resp.status_code == 422


def test_a_duplicate_name_is_refused_case_insensitively(client):
    make_journal(client, "u1", "Travel")
    resp = client.post("/journals", json={"name": "travel"}, headers=auth("u1"))
    assert resp.status_code == 409


def test_renaming_a_journal(client):
    j = make_journal(client, "u1", "Travel")
    resp = client.patch(f"/journals/{j['id']}", json={"name": "Trips"}, headers=auth("u1"))
    assert resp.status_code == 200
    assert resp.json()["name"] == "Trips"


def test_renaming_onto_another_journals_name_is_refused(client):
    make_journal(client, "u1", "Travel")
    other = make_journal(client, "u1", "Politics")
    resp = client.patch(f"/journals/{other['id']}", json={"name": "Travel"}, headers=auth("u1"))
    assert resp.status_code == 409


def test_renaming_a_journal_to_its_own_name_is_fine(client):
    """Saving the sheet unchanged must not trip the duplicate check on itself."""
    j = make_journal(client, "u1", "Travel")
    resp = client.patch(f"/journals/{j['id']}", json={"name": "Travel"}, headers=auth("u1"))
    assert resp.status_code == 200


def test_touching_another_users_journal_is_a_404(client):
    j = make_journal(client, "alice", "Travel")
    patched = client.patch(f"/journals/{j['id']}", json={"name": "x"}, headers=auth("bob"))
    assert patched.status_code == 404
    assert client.delete(f"/journals/{j['id']}", headers=auth("bob")).status_code == 404


# -- the tier ceiling ---------------------------------------------------------


def test_free_stops_at_two_journals(client):
    make_journal(client, "u1", "Travel")
    make_journal(client, "u1", "Politics")

    resp = client.post("/journals", json={"name": "Sports"}, headers=auth("u1"))
    assert resp.status_code == 403
    assert resp.json()["detail"] == {"error": "journal_limit", "limit": 2, "tier": "free"}


def test_premium_continues_past_the_free_ceiling(client):
    set_tier("u1", "premium")
    for i in range(5):
        make_journal(client, "u1", f"Journal {i}")
    assert len(client.get("/journals", headers=auth("u1")).json()) == 5


def test_the_profile_reports_the_ceiling_and_tracks_a_tier_change(client):
    assert client.get("/profile", headers=auth("u1")).json()["journals_max"] == 2
    set_tier("u1", "premium")
    assert client.get("/profile", headers=auth("u1")).json()["journals_max"] == 20


def test_lapsing_from_premium_keeps_every_journal_usable(client):
    """The point of the whole design: a downgrade is never destructive.

    Someone over the free ceiling keeps what they have and can still file,
    rename and delete. Only creating another is refused.
    """
    set_tier("u1", "premium")
    journals = [make_journal(client, "u1", f"Journal {i}") for i in range(5)]
    set_tier("u1", "free")

    assert len(client.get("/journals", headers=auth("u1")).json()) == 5

    renamed = client.patch(
        f"/journals/{journals[0]['id']}", json={"name": "Kept"}, headers=auth("u1")
    )
    assert renamed.status_code == 200

    filed = file_text(client, "u1", "A memory filed after lapsing.", journals[1]["id"])
    assert filed["journal_id"] == journals[1]["id"]

    assert client.delete(f"/journals/{journals[2]['id']}", headers=auth("u1")).status_code == 200
    assert client.post("/journals", json={"name": "More"}, headers=auth("u1")).status_code == 403


# -- filing -------------------------------------------------------------------


def test_a_memory_is_unfiled_by_default(make_text_memory):
    assert make_text_memory("u1", "An unfiled thought.")["journal_id"] == ""


def test_filing_at_capture_and_reassigning_later(client):
    travel = make_journal(client, "u1", "Travel")
    politics = make_journal(client, "u1", "Politics")

    created = file_text(client, "u1", "We drove up the coast.", travel["id"])

    moved = client.patch(
        f"/recordings/{created['id']}",
        json={"journal_id": politics["id"]},
        headers=auth("u1"),
    )
    assert moved.status_code == 200
    assert moved.json()["journal_id"] == politics["id"]

    unfiled = client.patch(
        f"/recordings/{created['id']}", json={"journal_id": ""}, headers=auth("u1")
    )
    assert unfiled.json()["journal_id"] == ""


def test_filing_into_a_journal_that_does_not_exist_is_a_404(client, make_text_memory):
    rec = make_text_memory("u1", "A thought.")
    resp = client.patch(
        f"/recordings/{rec['id']}", json={"journal_id": "nope"}, headers=auth("u1")
    )
    assert resp.status_code == 404
    # And the memory is untouched rather than half-written.
    view = client.get(f"/recordings/{rec['id']}", headers=auth("u1")).json()
    assert view["recording"]["journal_id"] == ""


def test_filing_into_another_users_journal_is_a_404(client, make_text_memory):
    alices = make_journal(client, "alice", "Travel")
    rec = make_text_memory("bob", "A thought.")
    resp = client.patch(
        f"/recordings/{rec['id']}", json={"journal_id": alices["id"]}, headers=auth("bob")
    )
    assert resp.status_code == 404


def test_starring_a_memory_does_not_disturb_its_journal(client):
    travel = make_journal(client, "u1", "Travel")
    rec = file_text(client, "u1", "We drove up the coast.", travel["id"])

    starred = client.patch(
        f"/recordings/{rec['id']}", json={"is_milestone": True}, headers=auth("u1")
    ).json()
    assert starred["is_milestone"] is True
    assert starred["journal_id"] == travel["id"]


def test_a_voice_memory_can_be_filed_at_capture(client):
    """The journal chip is on both modes of the record screen, not just Write."""
    travel = make_journal(client, "u1", "Travel")
    up = client.post("/uploads", json={}, headers=auth("u1")).json()
    client.post(
        "/dev/seed-transcript",
        json={"audio_path": up["audio_path"], "transcript": "The coast road.", "language": "en"},
        headers=auth("u1"),
    )
    resp = client.post(
        "/recordings",
        json={"audio_path": up["audio_path"], "duration_sec": 5.0, "journal_id": travel["id"]},
        headers=auth("u1"),
    )
    assert resp.status_code == 201
    assert resp.json()["journal_id"] == travel["id"]


# -- listing ------------------------------------------------------------------


def test_listing_filters_by_journal(client, make_text_memory):
    travel = make_journal(client, "u1", "Travel")
    file_text(client, "u1", "We drove up the coast.", travel["id"])
    make_text_memory("u1", "An unrelated thought.")

    filed = client.get(f"/recordings?journal_id={travel['id']}", headers=auth("u1")).json()
    assert [r["transcript"] for r in filed] == ["We drove up the coast."]

    assert len(client.get("/recordings", headers=auth("u1")).json()) == 2


def test_an_empty_journal_filter_means_unfiled_not_everything(client, make_text_memory):
    """`""` and "no filter at all" must not collapse into each other.

    Unfiled is the only route to the backlog of memories recorded before
    journals existed, so it has to be expressible.
    """
    travel = make_journal(client, "u1", "Travel")
    file_text(client, "u1", "We drove up the coast.", travel["id"])
    make_text_memory("u1", "An unrelated thought.")

    unfiled = client.get("/recordings?journal_id=", headers=auth("u1")).json()
    assert [r["transcript"] for r in unfiled] == ["An unrelated thought."]


# -- deletion -----------------------------------------------------------------


def test_deleting_a_journal_unfiles_its_memories_rather_than_deleting_them(client):
    travel = make_journal(client, "u1", "Travel")
    for text in ("The coast road.", "The ferry."):
        file_text(client, "u1", text, travel["id"])

    resp = client.delete(f"/journals/{travel['id']}", headers=auth("u1"))
    assert resp.status_code == 200
    assert resp.json() == {"unfiled": 2}

    assert client.get("/journals", headers=auth("u1")).json() == []
    rows = client.get("/recordings", headers=auth("u1")).json()
    assert len(rows) == 2, "the memories themselves must survive their journal"
    assert {r["journal_id"] for r in rows} == {""}


def test_deleting_a_journal_leaves_other_journals_alone(client):
    set_tier("u1", "premium")
    travel = make_journal(client, "u1", "Travel")
    politics = make_journal(client, "u1", "Politics")
    kept = file_text(client, "u1", "An argument at dinner.", politics["id"])

    client.delete(f"/journals/{travel['id']}", headers=auth("u1"))

    view = client.get(f"/recordings/{kept['id']}", headers=auth("u1")).json()
    assert view["recording"]["journal_id"] == politics["id"]


def test_deleting_a_journal_that_does_not_exist_is_a_404(client):
    assert client.delete("/journals/nope", headers=auth("u1")).status_code == 404


def test_deleting_a_memory_does_not_disturb_its_journal(client):
    travel = make_journal(client, "u1", "Travel")
    rec = file_text(client, "u1", "The coast road.", travel["id"])

    assert client.delete(f"/recordings/{rec['id']}", headers=auth("u1")).status_code == 204
    assert [j["name"] for j in client.get("/journals", headers=auth("u1")).json()] == ["Travel"]
