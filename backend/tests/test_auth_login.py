"""Logging in with a code, holding an account on two surfaces, and letting go.

These drive the real endpoints rather than the `auth()` shortcut, because what
they are about *is* the sign-in: one email means one account id however many
devices it is opened on, one phone and one browser hold it at a time, and
signing out hands that device to whoever picks it up next.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest

from app.services.otp import peek_mock_code
from tests.conftest import auth


def device(install_id: str, platform: str = "android", version: str = "1.0.0") -> dict:
    return {"X-Install-Id": install_id, "X-Platform": platform, "X-App-Version": version}


def code_for(email: str) -> str:
    code = peek_mock_code(email)
    assert code is not None, f"no code was issued for {email}"
    return code


def request_code(client, email: str, install_id: str = "phone-a", platform: str = "android"):
    return client.post(
        "/auth/otp/request", json={"email": email}, headers=device(install_id, platform)
    )


def verify(
    client,
    email: str,
    install_id: str = "phone-a",
    code: str | None = None,
    name: str = "",
    platform: str = "android",
):
    return client.post(
        "/auth/otp/verify",
        json={"email": email, "code": code or code_for(email), "preferred_name": name},
        headers=device(install_id, platform),
    )


def claim(client, ticket: str, takeover: bool = False):
    return client.post("/auth/session", json={"ticket": ticket, "takeover": takeover})


def log_in(
    client,
    email: str,
    install_id: str = "phone-a",
    name: str = "",
    takeover: bool = False,
    platform: str = "android",
):
    """The whole flow, as the app performs it. Returns the claim response body."""
    assert request_code(client, email, install_id, platform).status_code == 204
    verified = verify(client, email, install_id, name=name, platform=platform)
    assert verified.status_code == 200, verified.text
    claimed = claim(client, verified.json()["ticket"], takeover=takeover)
    assert claimed.status_code == 200, claimed.text
    return claimed.json()


def log_in_web(client, email: str, install_id: str = "browser-a", takeover: bool = False):
    """The same flow from a browser, which signs into the other surface."""
    return log_in(client, email, install_id, takeover=takeover, platform="web")


def signed_in(body: dict, platform: str = "android") -> dict:
    """Headers for a device that just logged in.

    The platform rides along because it is what a refusal is explained in terms
    of: a signed-out browser has to be told what replaced *the browser*.
    """
    return {
        "Authorization": f"Bearer {body['token']}",
        "X-Session-Id": body["session_id"],
        "X-Platform": platform,
    }


def signed_in_web(body: dict) -> dict:
    return signed_in(body, platform="web")


# -- asking for a code --------------------------------------------------


def test_a_code_can_be_asked_for_without_being_signed_in(client):
    """Necessarily unauthenticated: this is how someone with no session gets one."""
    assert client.post("/auth/otp/request", json={"email": "p@example.com"}).status_code == 204


def test_a_bad_address_is_refused(client):
    assert request_code(client, "not-an-email").status_code == 422


def test_asking_twice_in_a_row_is_throttled(client):
    request_code(client, "p@example.com")
    again = request_code(client, "p@example.com")
    assert again.status_code == 429
    assert "wait" in again.json()["detail"].lower()


def test_the_plaintext_code_is_never_stored(client):
    from app.services.firestore import get_repository

    request_code(client, "p@example.com")
    stored = get_repository().get_otp("p@example.com")
    assert stored is not None
    assert stored.code_sha256 != code_for("p@example.com")
    assert len(stored.code_sha256) == 64


# -- redeeming it -------------------------------------------------------


def test_a_wrong_code_is_refused_and_counts_down(client):
    request_code(client, "p@example.com")
    r = verify(client, "p@example.com", code="000000")
    assert r.status_code == 400
    assert "attempt" in r.json()["detail"].lower()


def test_too_many_wrong_codes_burns_the_challenge(client):
    request_code(client, "p@example.com")
    for _ in range(5):
        verify(client, "p@example.com", code="000000")
    assert verify(client, "p@example.com", code=code_for("p@example.com")).status_code == 400


def test_an_expired_code_is_refused(client):
    from app.services.firestore import get_repository

    request_code(client, "p@example.com")
    repo = get_repository()
    challenge = repo.get_otp("p@example.com")
    challenge.expires_at = datetime.now(timezone.utc) - timedelta(seconds=1)
    repo.save_otp(challenge)

    r = verify(client, "p@example.com")
    assert r.status_code == 400
    assert "expired" in r.json()["detail"].lower()


def test_a_code_cannot_be_redeemed_from_another_device(client):
    """The device that asked must be the device that answers, or a code glimpsed
    in someone else's inbox would be redeemable from anywhere."""
    request_code(client, "p@example.com", install_id="phone-a")
    r = verify(client, "p@example.com", install_id="phone-b")
    assert r.status_code == 400
    assert "another device" in r.json()["detail"]


def test_a_ticket_is_single_use(client):
    request_code(client, "p@example.com")
    ticket = verify(client, "p@example.com").json()["ticket"]
    assert claim(client, ticket).status_code == 200
    assert claim(client, ticket).status_code == 400


def test_an_unknown_ticket_is_refused(client):
    assert claim(client, "tkt_nonsense").status_code == 400


# -- one email, one account --------------------------------------------


def test_signing_up_then_back_in_keeps_the_same_account(client):
    first = log_in(client, "p@example.com", name="Prakash Annadurai")
    assert first["profile"]["email"] == "p@example.com"
    assert first["profile"]["preferred_name"] == "Prakash Annadurai"

    client.post("/auth/logout", headers=signed_in(first))
    again = log_in(client, "p@example.com")

    assert again["uid"] == first["uid"], "one address must not grow a second account"
    assert again["session_id"] != first["session_id"], "each sign-in is its own session"


def test_a_second_device_gets_the_same_id_and_the_same_memories(client, make_text_memory):
    phone = log_in(client, "p@example.com", install_id="phone-a")
    make_text_memory(phone["uid"], "We hiked the Kalsubai ridge at sunrise.")

    tablet = log_in(client, "p@example.com", install_id="tablet-b", takeover=True)

    assert tablet["uid"] == phone["uid"], "the account is the email, not the phone"
    memories = client.get("/recordings", headers=signed_in(tablet)).json()
    assert len(memories) == 1
    assert "Kalsubai" in memories[0]["transcript"]


def test_the_address_is_matched_case_insensitively(client):
    first = log_in(client, "p@example.com")
    client.post("/auth/logout", headers=signed_in(first))

    request_code(client, "P@Example.COM")
    ticket = verify(client, "P@Example.COM").json()
    assert ticket["status"] == "signed_in", "casing must not create a second account"
    assert claim(client, ticket["ticket"]).json()["uid"] == first["uid"]


def test_a_new_address_reports_a_signup(client):
    request_code(client, "new@example.com")
    assert verify(client, "new@example.com").json()["status"] == "signed_up"


# -- one device at a time ----------------------------------------------


def test_a_second_device_is_told_what_is_in_the_way(client):
    log_in(client, "p@example.com", install_id="phone-a")

    request_code(client, "p@example.com", install_id="tablet-b")
    body = verify(client, "p@example.com", install_id="tablet-b").json()

    assert body["active_session"] is not None
    assert body["active_session"]["device"] == "an Android phone"
    assert body["active_session"]["signed_in_at"]


def test_taking_over_has_to_be_asked_for(client):
    log_in(client, "p@example.com", install_id="phone-a")

    request_code(client, "p@example.com", install_id="tablet-b")
    ticket = verify(client, "p@example.com", install_id="tablet-b").json()["ticket"]

    refused = claim(client, ticket)
    assert refused.status_code == 409
    assert refused.json()["detail"]["code"] == "session_active"
    assert refused.json()["detail"]["active_session"]["device"] == "an Android phone"

    # The same ticket still works once the answer is yes — being asked a question
    # must not cost the person their sign-in.
    assert claim(client, ticket, takeover=True).status_code == 200


def test_the_replaced_device_is_told_why_on_its_next_request(client):
    phone = log_in(client, "p@example.com", install_id="phone-a")
    assert client.get("/recordings", headers=signed_in(phone)).status_code == 200

    log_in(client, "p@example.com", install_id="tablet-b", takeover=True)

    kicked = client.get("/recordings", headers=signed_in(phone))
    assert kicked.status_code == 401
    detail = kicked.json()["detail"]
    assert detail["code"] == "session_replaced"
    assert detail["device"] == "an Android phone"
    assert detail["signed_in_at"], "the old phone has to be able to say when"


def test_the_same_device_signing_in_again_is_not_a_takeover(client):
    """Reopening the app after a token expires, or logging back in on the same
    phone, is nobody's takeover — and being asked about yourself is nonsense."""
    log_in(client, "p@example.com", install_id="phone-a")

    request_code(client, "p@example.com", install_id="phone-a")
    body = verify(client, "p@example.com", install_id="phone-a").json()

    assert body["active_session"] is None
    assert claim(client, body["ticket"]).status_code == 200


def test_a_live_call_is_refused_for_a_replaced_session(client):
    """The socket is where a takeover is most likely to be noticed first."""
    import pytest as _pytest
    from starlette.websockets import WebSocketDisconnect

    phone = log_in(client, "p@example.com", install_id="phone-a")
    log_in(client, "p@example.com", install_id="tablet-b", takeover=True)

    with _pytest.raises(WebSocketDisconnect) as caught:
        with client.websocket_connect(
            f"/live?token={phone['uid']}&session={phone['session_id']}"
        ):
            pass
    assert caught.value.code == 4403


# -- signing out --------------------------------------------------------


def test_signing_out_ends_this_devices_hold(client):
    phone = log_in(client, "p@example.com")
    assert client.post("/auth/logout", headers=signed_in(phone)).status_code == 204

    after = client.get("/recordings", headers=signed_in(phone))
    assert after.status_code == 401
    assert after.json()["detail"]["code"] == "signed_out"


def test_signing_out_frees_the_account_for_a_clean_sign_in(client):
    """No takeover prompt after a proper sign-out: there is nothing to take over."""
    phone = log_in(client, "p@example.com", install_id="phone-a")
    client.post("/auth/logout", headers=signed_in(phone))

    request_code(client, "p@example.com", install_id="tablet-b")
    assert verify(client, "p@example.com", install_id="tablet-b").json()["active_session"] is None


def test_a_stale_device_cannot_sign_the_live_one_out(client):
    phone = log_in(client, "p@example.com", install_id="phone-a")
    tablet = log_in(client, "p@example.com", install_id="tablet-b", takeover=True)

    assert client.post("/auth/logout", headers=signed_in(phone)).status_code == 401
    assert client.get("/recordings", headers=signed_in(tablet)).status_code == 200


def test_one_phone_two_people(client, make_text_memory):
    """The whole point of sign-out: a shared phone, and nobody reading anyone
    else's diary."""
    alice = log_in(client, "alice@example.com", install_id="shared-phone")
    make_text_memory(alice["uid"], "Alice's private memory.")
    client.post("/auth/logout", headers=signed_in(alice))

    bob = log_in(client, "bob@example.com", install_id="shared-phone")
    make_text_memory(bob["uid"], "Bob's private memory.")

    assert bob["uid"] != alice["uid"]
    bobs = client.get("/recordings", headers=signed_in(bob)).json()
    assert [r["transcript"] for r in bobs] == ["Bob's private memory."]

    # And Alice's are still hers, waiting for her to sign back in.
    client.post("/auth/logout", headers=signed_in(bob))
    alice_again = log_in(client, "alice@example.com", install_id="shared-phone")
    hers = client.get("/recordings", headers=signed_in(alice_again)).json()
    assert [r["transcript"] for r in hers] == ["Alice's private memory."]


# -- the account itself -------------------------------------------------


def test_deleting_the_account_releases_the_email_and_the_session(client):
    body = log_in(client, "p@example.com")
    assert client.delete("/account", headers=signed_in(body)).status_code == 204

    assert client.get("/recordings", headers=signed_in(body)).status_code == 401
    # The address can start a fresh account rather than reopening the dead one.
    request_code(client, "p@example.com")
    fresh = verify(client, "p@example.com").json()
    assert fresh["status"] == "signed_up"
    assert claim(client, fresh["ticket"]).json()["uid"] != body["uid"]


def test_the_profile_reads_back_over_the_session(client):
    body = log_in(client, "p@example.com", name="Prakash Annadurai")
    profile = client.get("/profile", headers=signed_in(body)).json()
    assert profile["has_profile"] is True
    assert profile["email"] == "p@example.com"
    assert profile["preferred_name"] == "Prakash Annadurai"


def test_renaming_still_cannot_change_the_address(client):
    body = log_in(client, "p@example.com", name="Prakash")
    client.patch("/profile", json={"preferred_name": "Renamed"}, headers=signed_in(body))
    profile = client.get("/profile", headers=signed_in(body)).json()
    assert profile["preferred_name"] == "Renamed"
    assert profile["email"] == "p@example.com", "only the code flow can change the address"


def test_dismissing_the_signup_prompt_sticks(client):
    body = log_in(client, "p@example.com")
    r = client.patch("/profile", json={"signup_prompt_dismissed": True}, headers=signed_in(body))
    assert r.status_code == 200
    assert r.json()["signup_prompt_dismissed"] is True


# -- isolation ----------------------------------------------------------


def test_a_caller_cannot_name_the_account_to_open(client, make_text_memory):
    """Both the address and the account behind it are resolved server-side."""
    victim = log_in(client, "victim@example.com", install_id="victim-phone")
    make_text_memory(victim["uid"], "Victim's private memory.")

    request_code(client, "mallory@example.com", install_id="mallory-phone")
    stolen = client.post(
        "/auth/otp/verify",
        json={
            "email": "mallory@example.com",
            "code": code_for("mallory@example.com"),
            "uid": victim["uid"],
            "account_uid": victim["uid"],
        },
        headers=device("mallory-phone"),
    ).json()

    mallory = claim(client, stolen["ticket"]).json()
    assert mallory["uid"] != victim["uid"]
    assert client.get("/recordings", headers=signed_in(mallory)).json() == []


def test_guessing_someone_elses_code_fails(client, make_text_memory):
    victim = log_in(client, "victim@example.com", install_id="victim-phone")
    make_text_memory(victim["uid"], "Victim's private memory.")

    # Mallory can make a code be *sent* — to an inbox she cannot read.
    request_code(client, "victim@example.com", install_id="mallory-phone")
    r = verify(client, "victim@example.com", install_id="mallory-phone", code="000000")

    assert r.status_code == 400
    assert len(client.get("/recordings", headers=auth(victim["uid"])).json()) == 1


@pytest.mark.parametrize("field", ["ticket"])
def test_the_claim_needs_its_ticket(client, field):
    assert client.post("/auth/session", json={}).status_code == 422


# -- what to call them --------------------------------------------------
#
# The name is asked for after the code, and only when the account has none.
# Someone signing in on a second device has already answered it.


def test_a_new_address_is_asked_for_a_name(client):
    request_code(client, "new@example.com")
    assert verify(client, "new@example.com").json()["needs_name"] is True


def test_the_name_given_with_the_claim_is_kept(client):
    request_code(client, "new@example.com")
    ticket = verify(client, "new@example.com").json()["ticket"]

    claimed = client.post(
        "/auth/session", json={"ticket": ticket, "preferred_name": "  Prakash  "}
    ).json()

    assert claimed["profile"]["preferred_name"] == "Prakash"
    profile = client.get("/profile", headers=signed_in(claimed)).json()
    assert profile["preferred_name"] == "Prakash"


def test_a_named_account_is_not_asked_again_on_another_device(client):
    log_in(client, "p@example.com", install_id="phone-a", name="Prakash")

    request_code(client, "p@example.com", install_id="browser-a", platform="web")
    body = verify(client, "p@example.com", install_id="browser-a", platform="web").json()

    assert body["needs_name"] is False


def test_signing_in_cannot_rename_an_account_that_has_a_name(client):
    first = log_in(client, "p@example.com", name="Prakash")
    client.post("/auth/logout", headers=signed_in(first))

    request_code(client, "p@example.com")
    ticket = verify(client, "p@example.com").json()["ticket"]
    claimed = client.post(
        "/auth/session", json={"ticket": ticket, "preferred_name": "Someone Else"}
    ).json()

    assert claimed["profile"]["preferred_name"] == "Prakash"


def test_an_account_left_unnamed_is_asked_again_next_time(client):
    """Walking away from the question must not mean never being asked."""
    first = log_in(client, "p@example.com")  # no name given
    client.post("/auth/logout", headers=signed_in(first))

    request_code(client, "p@example.com")
    body = verify(client, "p@example.com").json()

    assert body["status"] == "signed_in"
    assert body["needs_name"] is True


def test_the_name_can_still_be_changed_from_the_profile(client):
    body = log_in(client, "p@example.com", name="Prakash")
    client.patch("/profile", json={"preferred_name": "PK"}, headers=signed_in(body))
    assert client.get("/profile", headers=signed_in(body)).json()["preferred_name"] == "PK"
