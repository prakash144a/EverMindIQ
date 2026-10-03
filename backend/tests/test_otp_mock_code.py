"""The pinned sign-in code that makes local development possible.

Mock mode sends no email, so a random code has to be read back out of the
process before anyone can sign in — which means a second window open on every
attempt. `VOICEIQ_MOCK_OTP_CODE` pins it instead.

What these are really about is the guard: a known code is a master key to any
account, and the only thing standing between "convenient locally" and that is
`effective_mock`. So the last test here is the important one.
"""

from __future__ import annotations

import pytest

from app.core.config import Settings
from app.services.otp import OtpService, peek_mock_code
from app.services.firestore import get_repository


def _settings(**overrides) -> Settings:
    base = dict(mock=True, gcp_project="", acs_connection_string="", acs_sender="")
    return Settings(**{**base, **overrides})


def test_a_pinned_code_is_the_code_that_is_issued():
    service = OtpService(_settings(mock_otp_code="123456"))
    issued = service.request_code(get_repository(), "p@example.com")

    assert issued == "123456"
    assert peek_mock_code("p@example.com") == "123456"


def test_a_pinned_code_actually_signs_someone_in(client):
    """The whole point: type the known code into the form and be let in."""
    from app.services import otp

    otp.reset_otp_service()
    otp._service = OtpService(_settings(mock_otp_code="123456"))
    try:
        device = {"X-Install-Id": "browser-a", "X-Platform": "web"}
        assert client.post(
            "/auth/otp/request", json={"email": "p@example.com"}, headers=device
        ).status_code == 204

        verified = client.post(
            "/auth/otp/verify",
            json={"email": "p@example.com", "code": "123456"},
            headers=device,
        )
        assert verified.status_code == 200, verified.text
        claimed = client.post("/auth/session", json={"ticket": verified.json()["ticket"]})
        assert claimed.status_code == 200
    finally:
        otp.reset_otp_service()


def test_a_wrong_code_is_still_wrong_when_one_is_pinned():
    """Pinning the code must not turn the check off."""
    service = OtpService(_settings(mock_otp_code="123456"))
    repo = get_repository()
    service.request_code(repo, "p@example.com")

    from app.services.otp import OtpError

    with pytest.raises(OtpError):
        service.verify_code(repo, "p@example.com", "000000")


def test_an_empty_pin_means_a_random_code():
    """What the test suite itself runs with, so a wrong guess is really wrong."""
    service = OtpService(_settings(mock_otp_code=""))
    repo = get_repository()

    seen = set()
    for _ in range(12):
        repo.delete_otp("p@example.com")
        seen.add(service.request_code(repo, "p@example.com"))

    assert len(seen) > 1, "codes should not repeat"
    assert all(len(code) == 6 and code.isdigit() for code in seen)


def test_a_real_deployment_cannot_issue_a_known_code():
    """The guard, and the reason this setting is safe to ship.

    A configured GCP project means `effective_mock` is false, and the pin is
    ignored no matter how it got set — an env var on the service, a stray line
    in a config file, someone copying local.env into production.
    """
    service = OtpService(_settings(mock=False, gcp_project="voiceiq-505205", mock_otp_code="123456"))
    assert service.settings.effective_mock is False
    assert service._pinned_code() == ""
