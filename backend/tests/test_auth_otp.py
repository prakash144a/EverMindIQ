"""Email-OTP signup, restore-after-reinstall, and the merge that comes with it."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest

from app.services.otp import peek_mock_code
from tests.conftest import auth


def code_for(email: str) -> str:
    code = peek_mock_code(email)
    assert code is not None, f"no code was issued for {email}"
    return code


def request_code(client, uid: str, email: str):
    return client.post("/auth/otp/request", json={"email": email}, headers=auth(uid))


def verify(client, uid: str, email: str, code: str | None = None, name: str = ""):
    return client.post(
        "/auth/otp/verify",
        json={"email": email, "code": code or code_for(email), "preferred_name": name},
        headers=auth(uid),
    )


def sign_up(client, uid: str, email: str, name: str = "Prakash Annadurai"):
    assert request_code(client, uid, email).status_code == 204
    r = verify(client, uid, email, name=name)
    assert r.status_code == 200, r.text
    return r.json()


# -- issuing ------------------------------------------------------------


def test_requesting_a_code_issues_one(client):
    assert request_code(client, "alice", "p@example.com").status_code == 204
    assert len(code_for("p@example.com")) == 6


def test_a_malformed_address_is_rejected(client):
    assert request_code(client, "alice", "not-an-email").status_code == 422


def test_requesting_requires_auth(client):
    assert client.post("/auth/otp/request", json={"email": "p@example.com"}).status_code in (
        401,
        403,
    )


def test_resending_too_soon_is_refused(client):
    request_code(client, "alice", "p@example.com")
    again = request_code(client, "alice", "p@example.com")
    assert again.status_code == 429
    assert "wait" in again.json()["detail"].lower()


def test_the_plaintext_code_is_never_stored(client):
    from app.services.firestore import get_repository

    request_code(client, "alice", "p@example.com")
    stored = get_repository().get_otp("p@example.com")
    assert stored is not None
    assert stored.code_sha256 != code_for("p@example.com")
    assert len(stored.code_sha256) == 64


# -- verifying ----------------------------------------------------------


def test_a_wrong_code_is_refused_and_counts_down(client):
    request_code(client, "alice", "p@example.com")
    r = verify(client, "alice", "p@example.com", code="000000")
    assert r.status_code == 400
    assert "attempt" in r.json()["detail"].lower()


def test_too_many_wrong_codes_burns_the_challenge(client):
    request_code(client, "alice", "p@example.com")
    for _ in range(5):
        verify(client, "alice", "p@example.com", code="000000")

    # Even the right code no longer works — a new one must be requested.
    r = verify(client, "alice", "p@example.com", code=code_for("p@example.com"))
    assert r.status_code == 400


def test_an_expired_code_is_refused(client):
    from app.services.firestore import get_repository

    request_code(client, "alice", "p@example.com")
    repo = get_repository()
    challenge = repo.get_otp("p@example.com")
    challenge.expires_at = datetime.now(timezone.utc) - timedelta(seconds=1)
    repo.save_otp(challenge)

    r = verify(client, "alice", "p@example.com")
    assert r.status_code == 400
    assert "expired" in r.json()["detail"].lower()


def test_a_code_works_only_once(client):
    sign_up(client, "alice", "p@example.com")
    replay = verify(client, "alice", "p@example.com", code=code_for("p@example.com"))
    assert replay.status_code == 400


def test_a_code_cannot_be_redeemed_by_a_different_caller(client):
    """The device that asked must be the device that answers."""
    request_code(client, "alice", "p@example.com")
    r = verify(client, "mallory", "p@example.com", code=code_for("p@example.com"))
    assert r.status_code == 400
    assert "another device" in r.json()["detail"].lower()


# -- signup -------------------------------------------------------------


def test_signup_keeps_the_uid_so_recordings_stay_attached(make_recording, client):
    rec = make_recording("alice", "A memory from before signing up.")

    body = sign_up(client, "alice", "p@example.com")

    assert body["status"] == "signed_up"
    assert body["merged"] is None, "nothing moves; the uid never changed"
    assert body["profile"]["has_profile"] is True
    assert body["profile"]["preferred_name"] == "Prakash Annadurai"

    listed = client.get("/recordings", headers=auth("alice")).json()
    assert [r["id"] for r in listed] == [rec["id"]]


def test_verifying_again_on_the_same_account_is_not_a_restore(client):
    sign_up(client, "alice", "p@example.com")
    assert request_code(client, "alice", "p@example.com").status_code == 204
    body = verify(client, "alice", "p@example.com").json()
    assert body["status"] == "verified"
    assert body["merged"] is None


def test_profile_is_readable_and_starts_empty(client):
    empty = client.get("/profile", headers=auth("alice")).json()
    assert empty["has_profile"] is False
    assert empty["preferred_name"] == ""

    sign_up(client, "alice", "p@example.com")
    filled = client.get("/profile", headers=auth("alice")).json()
    assert filled["has_profile"] is True
    assert filled["email"] == "p@example.com"


def test_dismissing_the_signup_prompt_sticks(client):
    r = client.patch("/profile", json={"signup_prompt_dismissed": True}, headers=auth("alice"))
    assert r.status_code == 200
    assert client.get("/profile", headers=auth("alice")).json()["signup_prompt_dismissed"] is True


def test_email_is_not_editable_through_the_profile_patch(client):
    sign_up(client, "alice", "p@example.com")
    client.patch("/profile", json={"preferred_name": "Renamed"}, headers=auth("alice"))
    profile = client.get("/profile", headers=auth("alice")).json()
    assert profile["preferred_name"] == "Renamed"
    assert profile["email"] == "p@example.com", "only the OTP flow can change the address"


# -- restore after reinstall --------------------------------------------


def test_restore_brings_the_account_onto_the_current_session(make_recording, client):
    """No re-authentication: the account moves to the caller, not the reverse.

    That keeps the app's Firebase session untouched, so there is no custom token
    to mint and the flow behaves the same locally as in the cloud.
    """
    make_recording("alice", "A memory from the first install.")
    sign_up(client, "alice", "p@example.com")

    # Reinstall: a brand-new anonymous uid, empty to start with.
    assert client.get("/recordings", headers=auth("fresh-uid")).json() == []

    assert request_code(client, "fresh-uid", "p@example.com").status_code == 204
    body = verify(client, "fresh-uid", "p@example.com").json()

    assert body["status"] == "restored"
    assert body["merged"]["recordings"] == 1
    assert body["profile"]["preferred_name"] == "Prakash Annadurai"

    # The caller keeps its own identity and now owns the memories.
    restored = client.get("/recordings", headers=auth("fresh-uid")).json()
    assert len(restored) == 1
    assert restored[0]["uid"] == "fresh-uid"
    assert client.get("/recordings", headers=auth("alice")).json() == []


def test_restore_keeps_what_was_recorded_before_signing_in(make_recording, client):
    make_recording("alice", "Memory from the first install.")
    sign_up(client, "alice", "p@example.com")

    # On the fresh install the user records before restoring.
    make_recording("fresh-uid", "Memory recorded on the new phone.")

    request_code(client, "fresh-uid", "p@example.com")
    body = verify(client, "fresh-uid", "p@example.com").json()

    assert body["status"] == "restored"
    combined = client.get("/recordings", headers=auth("fresh-uid")).json()
    assert len(combined) == 2, "nothing recorded before restoring may be lost"
    assert all(r["uid"] == "fresh-uid" for r in combined)


def test_restored_recordings_are_searchable(make_recording, client):
    make_recording("alice", "We hiked Table Mountain with Sarah.")
    sign_up(client, "alice", "p@example.com")

    request_code(client, "fresh-uid", "p@example.com")
    verify(client, "fresh-uid", "p@example.com")

    answer = client.post("/chat", json={"question": "Table Mountain"}, headers=auth("fresh-uid"))
    assert answer.status_code == 200
    assert answer.json()["citations"], "restored chunks must remain reachable by recall"


def test_the_email_follows_the_live_session(make_recording, client):
    """A second reinstall must restore from wherever the memories now live."""
    make_recording("alice", "Original memory.")
    sign_up(client, "alice", "p@example.com")

    request_code(client, "install-2", "p@example.com")
    verify(client, "install-2", "p@example.com")

    request_code(client, "install-3", "p@example.com")
    body = verify(client, "install-3", "p@example.com").json()

    assert body["status"] == "restored"
    assert len(client.get("/recordings", headers=auth("install-3")).json()) == 1


def test_restore_carries_the_accounts_settings_over(make_recording, client):
    sign_up(client, "alice", "p@example.com")
    client.put(
        "/settings",
        json={"answer_language": "ta", "slideshow_interval_sec": 9},
        headers=auth("alice"),
    )

    request_code(client, "fresh-uid", "p@example.com")
    verify(client, "fresh-uid", "p@example.com")

    restored = client.get("/settings", headers=auth("fresh-uid")).json()
    assert restored["answer_language"] == "ta"
    assert restored["slideshow_interval_sec"] == 9


# -- isolation ----------------------------------------------------------


def test_a_caller_cannot_name_the_uid_to_merge_into(make_recording, client):
    """Both sides of a merge are derived server-side, never from the request."""
    make_recording("victim", "Victim's private memory.")
    sign_up(client, "victim", "victim@example.com")

    # Mallory tries to pass a uid; the model has no such field, so it's ignored,
    # and the email she can actually verify is her own.
    r = client.post(
        "/auth/otp/verify",
        json={
            "email": "victim@example.com",
            "code": "000000",
            "uid": "victim",
            "account_uid": "victim",
        },
        headers=auth("mallory"),
    )
    assert r.status_code == 400  # no valid code for that address from this caller
    assert len(client.get("/recordings", headers=auth("victim")).json()) == 1
    assert client.get("/recordings", headers=auth("mallory")).json() == []


def test_restoring_needs_a_code_from_the_real_inbox(make_recording, client):
    make_recording("victim", "Victim's private memory.")
    sign_up(client, "victim", "victim@example.com")

    # Mallory can request a code for someone else's address — it goes to their
    # inbox, which she cannot read — but guessing it must fail.
    request_code(client, "mallory", "victim@example.com")
    r = verify(client, "mallory", "victim@example.com", code="000000")

    assert r.status_code == 400
    assert client.get("/recordings", headers=auth("mallory")).json() == []
    assert len(client.get("/recordings", headers=auth("victim")).json()) == 1


def test_one_users_signup_does_not_touch_another(make_recording, client):
    make_recording("alice", "Alice's memory.")
    make_recording("bob", "Bob's memory.")

    sign_up(client, "alice", "alice@example.com")

    assert len(client.get("/recordings", headers=auth("bob")).json()) == 1
    assert client.get("/profile", headers=auth("bob")).json()["has_profile"] is False


def test_deleting_the_account_releases_the_email(client):
    sign_up(client, "alice", "p@example.com")
    assert client.delete("/account", headers=auth("alice")).status_code == 204

    # The address can now start a fresh account rather than restoring the old one.
    body = sign_up(client, "someone-new", "p@example.com", name="Dhivya")
    assert body["status"] == "signed_up"


@pytest.mark.parametrize("email", ["P@Example.COM", " p@example.com "])
def test_the_address_is_matched_case_insensitively(make_recording, client, email):
    make_recording("alice", "A memory.")
    sign_up(client, "alice", "p@example.com")

    assert request_code(client, "fresh", email).status_code == 204
    body = verify(client, "fresh", email).json()
    assert body["status"] == "restored", "casing must not create a second account"
    assert len(client.get("/recordings", headers=auth("fresh")).json()) == 1
