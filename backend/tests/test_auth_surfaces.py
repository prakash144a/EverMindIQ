"""A phone and a browser, signed into one account at the same time.

An account has two *surfaces* and holds one session in each. Signing in on a
laptop does not sign the phone in someone's pocket out, and a memory recorded in
either place shows up in the other — because the memories belong to the account,
not to the device that captured them.

Within a surface nothing has relaxed: a second phone still displaces the first,
and a second browser still displaces the first. Those rules live in
`test_auth_login.py`, whose flow helpers these reuse.
"""

from __future__ import annotations

from tests.test_auth_login import (
    claim,
    log_in,
    log_in_web,
    request_code,
    signed_in,
    signed_in_web,
    verify,
)

# -- two places at once -------------------------------------------------


def test_opening_the_web_app_leaves_the_phone_signed_in(client):
    """The whole point of surfaces: a laptop is not the phone in your pocket."""
    phone = log_in(client, "p@example.com", install_id="phone-a")
    browser = log_in_web(client, "p@example.com", install_id="browser-a")

    assert browser["uid"] == phone["uid"], "the account is the email, not the device"
    assert browser["session_id"] != phone["session_id"], "each surface holds its own"
    assert client.get("/recordings", headers=signed_in(phone)).status_code == 200
    assert client.get("/recordings", headers=signed_in_web(browser)).status_code == 200


def test_a_browser_is_not_asked_about_the_phone(client):
    """Nothing is in the way, so nothing is asked — and no takeover is needed."""
    log_in(client, "p@example.com", install_id="phone-a")

    request_code(client, "p@example.com", install_id="browser-a", platform="web")
    body = verify(client, "p@example.com", install_id="browser-a", platform="web").json()

    assert body["active_session"] is None
    assert claim(client, body["ticket"]).status_code == 200, "no takeover should be needed"


def test_a_memory_recorded_on_the_web_shows_up_on_the_phone(client):
    """What holding both is *for*."""
    phone = log_in(client, "p@example.com", install_id="phone-a")
    browser = log_in_web(client, "p@example.com", install_id="browser-a")

    made = client.post(
        "/recordings/text",
        json={"text": "Signed the papers on the Pune flat this morning."},
        headers=signed_in_web(browser),
    )
    assert made.status_code in (200, 201), made.text

    on_the_phone = client.get("/recordings", headers=signed_in(phone)).json()
    assert [r["transcript"] for r in on_the_phone] == [
        "Signed the papers on the Pune flat this morning."
    ]


def test_a_memory_recorded_on_the_phone_shows_up_on_the_web(client):
    phone = log_in(client, "p@example.com", install_id="phone-a")
    browser = log_in_web(client, "p@example.com", install_id="browser-a")

    client.post(
        "/recordings/text",
        json={"text": "Amma called about the Diwali plans."},
        headers=signed_in(phone),
    )

    in_the_browser = client.get("/recordings", headers=signed_in_web(browser)).json()
    assert [r["transcript"] for r in in_the_browser] == ["Amma called about the Diwali plans."]


def test_recall_can_be_spoken_from_the_browser(client):
    """Voice recall rides the `/live` socket, and either surface may hold it."""
    log_in(client, "p@example.com", install_id="phone-a")
    browser = log_in_web(client, "p@example.com", install_id="browser-a")

    with client.websocket_connect(
        f"/live?token={browser['uid']}&session={browser['session_id']}"
    ) as socket:
        assert socket is not None


# -- and still one at a time within each --------------------------------


def test_a_second_browser_displaces_only_the_first_browser(client):
    phone = log_in(client, "p@example.com", install_id="phone-a")
    first = log_in_web(client, "p@example.com", install_id="browser-a")

    request_code(client, "p@example.com", install_id="browser-b", platform="web")
    asked = verify(client, "p@example.com", install_id="browser-b", platform="web").json()
    assert asked["active_session"]["device"] == "a web browser", "within a surface, still one"

    second = claim(client, asked["ticket"], takeover=True).json()

    assert client.get("/recordings", headers=signed_in_web(first)).status_code == 401
    assert client.get("/recordings", headers=signed_in_web(second)).status_code == 200
    assert client.get("/recordings", headers=signed_in(phone)).status_code == 200


def test_a_second_phone_displaces_only_the_first_phone(client):
    first = log_in(client, "p@example.com", install_id="phone-a")
    browser = log_in_web(client, "p@example.com", install_id="browser-a")

    second = log_in(client, "p@example.com", install_id="phone-b", takeover=True)

    assert client.get("/recordings", headers=signed_in(first)).status_code == 401
    assert client.get("/recordings", headers=signed_in(second)).status_code == 200
    assert client.get("/recordings", headers=signed_in_web(browser)).status_code == 200


def test_a_replaced_browser_is_told_a_browser_replaced_it(client):
    log_in(client, "p@example.com", install_id="phone-a")
    first = log_in_web(client, "p@example.com", install_id="browser-a")
    log_in_web(client, "p@example.com", install_id="browser-b", takeover=True)

    kicked = client.get("/recordings", headers=signed_in_web(first))
    assert kicked.status_code == 401
    detail = kicked.json()["detail"]
    assert detail["code"] == "session_replaced"
    assert detail["device"] == "a web browser", "not the phone, which never went anywhere"


# -- letting go ---------------------------------------------------------


def test_closing_the_browser_session_leaves_the_phone_alone(client):
    phone = log_in(client, "p@example.com", install_id="phone-a")
    browser = log_in_web(client, "p@example.com", install_id="browser-a")

    assert client.post("/auth/logout", headers=signed_in_web(browser)).status_code == 204

    assert client.get("/recordings", headers=signed_in_web(browser)).status_code == 401
    assert client.get("/recordings", headers=signed_in(phone)).status_code == 200


def test_signing_out_of_the_phone_leaves_the_browser_alone(client):
    phone = log_in(client, "p@example.com", install_id="phone-a")
    browser = log_in_web(client, "p@example.com", install_id="browser-a")

    assert client.post("/auth/logout", headers=signed_in(phone)).status_code == 204

    assert client.get("/recordings", headers=signed_in(phone)).status_code == 401
    assert client.get("/recordings", headers=signed_in_web(browser)).status_code == 200


def test_deleting_the_account_ends_both_surfaces(client):
    phone = log_in(client, "p@example.com", install_id="phone-a")
    browser = log_in_web(client, "p@example.com", install_id="browser-a")

    assert client.delete("/account", headers=signed_in(phone)).status_code == 204

    assert client.get("/recordings", headers=signed_in(phone)).status_code == 401
    assert client.get("/recordings", headers=signed_in_web(browser)).status_code == 401


# -- what a caller may not talk its way into ----------------------------


def test_a_dead_session_cannot_be_revived_by_claiming_a_platform(client):
    """`X-Platform` is the caller's own word. It picks the wording of a refusal
    and nothing else — a replaced session stays replaced however it describes
    itself."""
    browser = log_in_web(client, "p@example.com", install_id="browser-a")
    log_in_web(client, "p@example.com", install_id="browser-b", takeover=True)

    for claimed in ("android", "web", "", "nonsense"):
        refused = client.get("/recordings", headers=signed_in(browser, platform=claimed))
        assert refused.status_code == 401, f"a dead session passed as {claimed!r}"


def test_an_unrecognised_platform_signs_into_the_mobile_slot(client):
    """A client we have never heard of must not mint itself a third session."""
    phone = log_in(client, "p@example.com", install_id="phone-a")
    odd = log_in(
        client, "p@example.com", install_id="fridge-b", takeover=True, platform="toaster"
    )

    assert client.get("/recordings", headers=signed_in(phone)).status_code == 401
    assert (
        client.get("/recordings", headers=signed_in(odd, platform="toaster")).status_code == 200
    )


def test_a_session_stored_before_surfaces_existed_is_still_honoured(client):
    """The deploy that introduces surfaces must not sign the field out.

    Documents written by the previous build hold a bare session at the top level
    of ``sessions/{uid}``; they are read as the slot their platform names.
    """
    from app.services.firestore import _sessions_from_document

    legacy = _sessions_from_document(
        {
            "session_id": "ses-old",
            "install_id": "phone-a",
            "platform": "android",
            "app_version": "1.0.0",
            "signed_in_at": "2026-09-01T10:00:00+00:00",
        }
    )
    assert list(legacy) == ["mobile"]
    assert legacy["mobile"].session_id == "ses-old"

    assert _sessions_from_document(None) == {}
    assert _sessions_from_document({}) == {}
